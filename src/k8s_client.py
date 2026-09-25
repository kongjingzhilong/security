# src/k8s_client.py
from kubernetes import client, config
import os
# 加载集群内配置或 kubeconfig
try:
    config.load_incluster_config()
except:
    config.load_kubeconfig(os.environ.get('KUBECONFIG', '~/.kube/config'))
api = client.CustomObjectsApi()
def create_dynamic_constraint(name, blocked_images, blocked_users, severity):
    """
    动态创建 OPA Gatekeeper Constraint
    """
    constraint = {
        'apiVersion': 'constraints.gatekeeper.sh/v1beta1',
        'kind': 'K8sImagePolicy',
        'metadata': {
            'name': name
        },
        'spec': {
            'match': {
                'kinds': [
                    {'apiGroups': [''], 'kinds': ['Pod']}
                ]
            },
            'parameters': {
                'blockedImages': blocked_images,
                'blockedUsers': [int(u) for u in blocked_users if u.isdigit()] if blocked_users else [],
                'severity': severity
            }
        }
    }
    try:
        api.create_cluster_custom_object(
            group='constraints.gatekeeper.sh',
            version='v1beta1',
            plural='k8simagepolicies',
            body=constraint
        )
        print(f"✅ 动态策略已创建: {name}")
        return True
    except Exception as e:
        print(f"❌ 创建策略失败 {name}: {e}")
        return False
def delete_dynamic_constraint(name):
    """删除动态策略"""
    try:
        api.delete_cluster_custom_object(
            group='constraints.gatekeeper.sh',
            version='v1beta1',
            plural='k8simagepolicies',
            name=name
        )
        print(f"🗑️ 动态策略已删除: {name}")
        return True
    except Exception as e:
        print(f"❌ 删除策略失败 {name}: {e}")
        return False
