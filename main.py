import json
import hashlib
from flask import Flask, request, jsonify
from src.parser import parse_falco_output
from src.time_window import check_chain, reset_chain
from src.dread import calculate_dread
from src.db import insert_alert, insert_dread_score, insert_dynamic_policy
from src.image_policy import generate_policy_from_alert
from src.hmac_auth import verify_hmac
app = Flask(__name__)
@app.route('/webhook', methods=['POST'])
def handle_webhook():
    """
    接收 Falcosidekick 转发的 Falco 告警
    """
    payload = request.get_data()
    signature = request.headers.get('X-Signature', '')
    if not verify_hmac(payload, signature):
        return jsonify({'error': 'Invalid signature'}), 401
    try:
        alert = json.loads(payload)
    except json.JSONDecodeError:
        return jsonify({'error': 'Invalid JSON'}), 400
    # 只处理 Falco 告警
    if alert.get('source') != 'syscall':
        return jsonify({'status': 'ignored'}), 200
    rule_name = alert.get('rule', 'Unknown')
    priority = alert.get('priority', 'INFO')
    output_text = alert.get('output', '')
    # 解析告警字段
    parsed = parse_falco_output(output_text)
    parsed['priority'] = priority
    container_id = parsed.get('container_id') or 'unknown'
    attack_stage = parsed.get('attack_stage', 0)
    # 生成 chain_id
    is_chain_complete, chain_id = check_chain(container_id, attack_stage, rule_name)
    # 写入数据库
    alert_id = insert_alert(
        rule_name=rule_name,
        priority=priority,
        container_id=container_id,
        container_image=parsed.get('container_image'),
        process_name=parsed.get('process_name'),
        user_name=parsed.get('user_name'),
        output_text=output_text,
        attack_stage=attack_stage,
        chain_id=chain_id
    )
    print(f"[{priority}] {rule_name} | stage={attack_stage} | chain={chain_id}")
    # 计算 DREAD 评分
    dread = calculate_dread(parsed)
    insert_dread_score(
        alert_id=alert_id,
        damage=dread['damage'],
        reproducibility=dread['reproducibility'],
        exploitability=dread['exploitability'],
        affected_users=dread['affected_users'],
        discoverability=dread['discoverability'],
        total_score=dread['total_score'],
        risk_level=dread['risk_level']
    )
    print(f"  DREAD: {dread['total_score']} ({dread['risk_level']})")
    # 如果攻击链完成或风险等级足够高 → 生成动态 OPA 策略
    if is_chain_complete or dread['risk_level'] in ('CRITICAL', 'HIGH'):
        policy = generate_policy_from_alert(parsed, dread, chain_id)
        if policy:
            insert_dynamic_policy(
                policy_name=policy['policy_name'],
                blocked_images=policy['blocked_images'],
                blocked_users=policy['blocked_users'],
                severity=policy['severity'],
                alert_id=alert_id
            )
            print(f"  🛡️ 动态策略已部署: {policy['policy_name']}")
        # 重置攻击链状态
        reset_chain(container_id)
    return jsonify({'status': 'processed', 'chain_id': chain_id}), 200
@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok'}), 200
if __name__ == '__main__':
    print("🚀 Falco-OPA 联动服务启动中...")
    print("   Webhook 端点: http://0.0.0.0:8080/webhook")
    app.run(host='0.0.0.0', port=8080, debug=False)
