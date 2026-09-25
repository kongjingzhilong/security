# src/dread.py
def calculate_dread(alert_data):
    """
    DREAD 风险评估模型
    D - Damage potential (破坏力)
    R - Reproducibility (可复现性)
    E - Exploitability (可利用性)
    A - Affected users (受影响用户)
    D - Discoverability (可发现性)
    每项 1-10 分，总分取平均
    """
    priority = alert_data.get('priority', 'INFO').upper()
    # 根据 Falco priority 映射基础分数
    priority_scores = {
        'EMERGENCY': 10,
        'CRITICAL': 9,
        'ERROR': 7,
        'WARNING': 5,
        'NOTICE': 3,
        'INFO': 2,
        'DEBUG': 1
    }
    base = priority_scores.get(priority, 3)
    # 根据攻击阶段调整各维度
    stage = alert_data.get('attack_stage', 0)
    damage = min(10, base + stage * 1)          # 阶段越高，破坏力越大
    reproducibility = min(10, base)             # 可复现性
    exploitability = min(10, base + stage)      # 阶段越高，利用难度越低
    affected_users = min(10, base - 1 if stage < 2 else base + 1)
    discoverability = min(10, base)
    total = (damage + reproducibility + exploitability + affected_users + discoverability) / 5.0
    if total >= 8.0:
        risk_level = "CRITICAL"
    elif total >= 6.0:
        risk_level = "HIGH"
    elif total >= 4.0:
        risk_level = "MEDIUM"
    else:
        risk_level = "LOW"
    return {
        'damage': damage,
        'reproducibility': reproducibility,
        'exploitability': exploitability,
        'affected_users': affected_users,
        'discoverability': discoverability,
        'total_score': round(total, 2),
        'risk_level': risk_level
    }
