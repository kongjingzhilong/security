import time
from collections import defaultdict
from src.db import get_alerts_by_chain
# 攻击链状态存储（内存）
attack_chains = defaultdict(lambda: {'stages': set(), 'first_seen': time.time()})
# 时间窗口：300秒内完成多步攻击才认定为攻击链
WINDOW_SECONDS = 300
def check_chain(container_id, attack_stage, rule_name):
    """
    检查某个容器是否在时间窗口内触发了多步攻击
    返回: (是否完成攻击链, chain_id)
    """
    chain = attack_chains[container_id]
    chain['stages'].add(attack_stage)
    # 清理过期记录
    if time.time() - chain['first_seen'] > WINDOW_SECONDS:
        chain['stages'] = {attack_stage}
        chain['first_seen'] = time.time()
    # 判断是否完成攻击链（至少触发 3 个不同阶段）
    if len(chain['stages']) >= 3:
        chain_id = f"chain-{container_id[:12]}"
        return True, chain_id
    return False, f"chain-{container_id[:12]}"
def reset_chain(container_id):
    """攻击链处理完毕后重置状态"""
    if container_id in attack_chains:
        del attack_chains[container_id]
