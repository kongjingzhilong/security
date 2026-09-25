# src/image_policy.py
from src.k8s_client import create_dynamic_constraint
def generate_policy_from_alert(alert_data, dread_result, chain_id):
    """
    根据告警和 DREAD 评分生成动态 OPA 约束策略
    """
    blocked_images = []
    blocked_users = []
    # HIGH 及以上风险才封禁镜像
    if dread_result['risk_level'] in ('CRITICAL', 'HIGH'):
        if alert_data.get('container_image'):
            # 取镜像前缀进行模糊匹配
            img = alert_data['container_image']
            if ':' in img:
                img = img.split(':')[0]
            blocked_images.append(img)
    # 攻击阶段 >= 2 时封禁用户
    if alert_data.get('attack_stage', 0) >= 2:
        if alert_data.get('user_name'):
            blocked_users.append(alert_data['user_name'])
    if not blocked_images and not blocked_users:
        return None
    policy_name = f"dynamic-block-{chain_id}"
    severity = dread_result['risk_level']
    # 调用 K8s API 创建 Constraint
    created = create_dynamic_constraint(
        name=policy_name,
        blocked_images=blocked_images,
        blocked_users=blocked_users,
        severity=severity
    )
    return {
        'policy_name': policy_name,
        'blocked_images': blocked_images,
        'blocked_users': blocked_users,
        'severity': severity,
        'created': created
    }
