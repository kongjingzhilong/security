import hmac
import hashlib
import os
WEBHOOK_SECRET = os.environ.get('WEBHOOK_SECRET', 'falco-opa-shared-secret-key')
# falcosidekick 的 webhook 输出不支持生成 HMAC 签名(仅有静态 customHeaders,
# 无法对逐条变化的 payload 计算摘要)。因此联调/演示环境可显式关闭签名校验:
#   export WEBHOOK_REQUIRE_SIGNATURE=false
# 生产环境请保持默认 true,并在网关/反向代理层注入签名。
REQUIRE_SIGNATURE = os.environ.get('WEBHOOK_REQUIRE_SIGNATURE', 'true').lower() not in ('0', 'false', 'no')
def verify_hmac(payload_bytes, signature):
    """
    验证 Falcosidekick 发来的 HMAC-SHA256 签名
    返回 True 表示放行(未启用校验时直接放行)
    """
    if not REQUIRE_SIGNATURE:
        return True
    if not signature:
        return False
    expected = hmac.new(
        WEBHOOK_SECRET.encode('utf-8'),
        payload_bytes,
        hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)
