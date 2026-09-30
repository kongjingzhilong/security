import re
def parse_falco_output(output_text, output_fields=None):
    """
    解析 Falco 告警，提取关键信息

    优先使用 Falco 引擎给出的结构化 output_fields(权威且稳定),
    仅在其缺失时回退到对 output 文本做正则匹配。
    注: 原实现只做正则,且正则写成 container= / image= ,
        而 Falco 实际输出的是 container_id= / container_image_repository= ,
        导致 container_image 恒为 None、无法生成动态封禁策略。
    """
    output_fields = output_fields or {}
    data = {
        'container_id': None,
        'container_image': None,
        'process_name': None,
        'user_name': None,
        'file_name': None,
        'attack_stage': 0,
    }
    # ---------- 1) 结构化字段优先 ----------
    data['container_id'] = (
        output_fields.get('container.id')
        or output_fields.get('container_id')
    )
    # 镜像:优先 repository,其次拼 tag
    image = output_fields.get('container.image.repository')
    if image and output_fields.get('container.image.tag'):
        image = f"{image}:{output_fields['container.image.tag']}"
    data['container_image'] = image
    data['process_name'] = output_fields.get('proc.name')
    data['user_name'] = output_fields.get('user.name')
    data['file_name'] = output_fields.get('fd.name')
    # ---------- 2) 缺失时回退正则 ----------
    if not data['container_id']:
        match = re.search(r'container_id=([a-f0-9]+)', output_text)
        if match:
            data['container_id'] = match.group(1)
    if not data['container_image']:
        # 匹配 container_image_repository=xxx 或 image=xxx
        match = re.search(r'container_image_repository=([^\s]+)', output_text) \
                or re.search(r'image=([^\s]+)', output_text)
        if match and match.group(1) not in ('<NA>', ''):
            data['container_image'] = match.group(1)
    if not data['process_name']:
        match = re.search(r'process=([^\s]+)', output_text)
        if match:
            data['process_name'] = match.group(1)
    if not data['user_name']:
        match = re.search(r'user=([^\s]+)', output_text)
        if match and match.group(1) not in ('<NA>', ''):
            data['user_name'] = match.group(1)
    if not data['file_name']:
        match = re.search(r'file=([^\s]+)', output_text)
        if match:
            data['file_name'] = match.group(1)
    # ---------- 3) 攻击阶段判定(基于规则名语义) ----------
    hay = (output_text or '').lower()
    if 'stage1' in hay or 'shell' in hay or 'spawned process' in hay:
        data['attack_stage'] = 1
    elif 'stage2' in hay or 'shadow' in hay or 'ssh' in hay or 'sensitive file' in hay:
        data['attack_stage'] = 2
    elif 'stage3' in hay or 'privilege' in hay or 'setuid' in hay:
        data['attack_stage'] = 3
    elif 'stage4' in hay or 'lateral' in hay or 'drop and execute' in hay:
        data['attack_stage'] = 4
    elif 'complete' in hay or 'chain' in hay:
        data['attack_stage'] = 5
    return data
