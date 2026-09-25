import hmac
import hashlib
import os
WEBHOOK_SECRET = os.environ.get('WEBHOOK_SECRET', 'falco-opa-shared-secret-key')
def verify_hmac(payload_bytes, signature):
    """
    验证 Falcosidekick 发来的 HMAC-SHA256 签名
    """
    if not signature:
        return False
    expected = hmac.new(
        WEBHOOK_SECRET.encode('utf-8'),
        payload_bytes,
        hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)
