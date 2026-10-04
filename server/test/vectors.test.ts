import { readFileSync } from 'node:fs';

import { decodeBase64url, deviceIdOf, ed25519Key, inviteProofCanonical, requestCanonical, verifyEd25519 } from 'src/common/crypto/relay_crypto';

// 协议 v1 测试向量：客户端 test/social_protocol_test.dart 读同一份文件，双端逐字节一致。
const vectors = JSON.parse(readFileSync(new URL('./vectors/protocol_v1.json', import.meta.url), 'utf8'));

describe('协议 v1 测试向量', () => {
  it('设备号由签名公钥哈希而来', () => {
    expect(deviceIdOf(decodeBase64url(vectors.signPublicKey, 32)!)).toBe(vectors.deviceId);
  });

  it('请求签名原文与签名可验', () => {
    const request = vectors.request;
    const canonical = requestCanonical(request.method, request.path, request.time, request.nonce, Buffer.from(request.body, 'utf8'));
    expect(canonical.toString('utf8')).toBe(request.canonical);
    expect(verifyEd25519(ed25519Key(decodeBase64url(vectors.signPublicKey, 32)!), canonical, decodeBase64url(request.signature, 64)!)).toBe(true);
  });

  it('邀请凭证原文与签名可验', () => {
    const invite = vectors.invite;
    const canonical = inviteProofCanonical(invite.inviteId, invite.redeemerDeviceId);
    expect(canonical.toString('utf8')).toBe(invite.canonical);
    expect(verifyEd25519(ed25519Key(decodeBase64url(invite.publicKey, 32)!), canonical, decodeBase64url(invite.proof, 64)!)).toBe(true);
  });

  it('base64url 只认规范写法', () => {
    expect(decodeBase64url('AA==')).toBeNull();
    expect(decodeBase64url('A+A')).toBeNull();
    expect(decodeBase64url(vectors.deviceId, 16)).not.toBeNull();
    expect(decodeBase64url(vectors.deviceId, 32)).toBeNull();
  });
});
