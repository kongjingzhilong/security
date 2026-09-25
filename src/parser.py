import re
def parse_falco_output(output_text):
    """
    解析 Falco 告警 output 字段，提取关键信息
    """
    data = {
        'container_id': None,
        'container_image': None,
        'process_name': None,
        'user_name': None,
        'file_name': None,
        'attack_stage': 0,
    }
    # 提取 container.id
    match = re.search(r'container=([a-f0-9]+)', output_text)
    if match:
        data['container_id'] = match.group(1)
    # 提取 container.image.repository
    match = re.search(r'image=([^\s]+)', output_text)
    if match:
        data['container_image'] = match.group(1)
    # 提取 proc.name
    match = re.search(r'process=([^\s]+)', output_text)
    if match:
        data['process_name'] = match.group(1)
    # 提取 user.name
    match = re.search(r'user=([^\s]+)', output_text)
    if match:
        data['user_name'] = match.group(1)
    # 提取 fd.name
    match = re.search(r'file=([^\s]+)', output_text)
    if match:
        data['file_name'] = match.group(1)
    # 根据规则名判断攻击阶段
    rule_name = output_text.lower()
    if 'stage1' in rule_name or 'shell' in rule_name:
        data['attack_stage'] = 1
    elif 'stage2' in rule_name or 'shadow' in rule_name or 'ssh' in rule_name:
        data['attack_stage'] = 2
    elif 'stage3' in rule_name or 'privilege' in rule_name or 'setuid' in rule_name:
        data['attack_stage'] = 3
    elif 'stage4' in rule_name or 'lateral' in rule_name:
        data['attack_stage'] = 4
    elif 'complete' in rule_name or 'chain' in rule_name:
        data['attack_stage'] = 5
    return data
