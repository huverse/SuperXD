import { readFileSync } from 'node:fs';

import { createPrivateKey, sign } from 'node:crypto';

import { base64url, decodeBase64url, deviceIdOf, ed25519Key, friendKeysCanonical, inviteProofCanonical, requestCanonical, rewardPrizeCanonical, socialBindCanonical, verifyEd25519, x25519PrivateKey, x25519PublicOf } from 'src/common/crypto/relay_crypto';
import { sealRewardPrize, sealSignedRewardPrize } from 'src/modules/reward/reward_seal';

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

  it('服务器给好友公钥的签名原文与签名可验', () => {
    const keys = vectors.friendKeys;
    const canonical = friendKeysCanonical(keys.ownerDeviceId, keys.deviceId, keys.signPublicKey, keys.boxPublicKey, keys.movedFrom);
    expect(canonical.toString('utf8')).toBe(keys.canonical);
    expect(verifyEd25519(ed25519Key(decodeBase64url(keys.publicKey, 32)!), canonical, decodeBase64url(keys.signature, 64)!)).toBe(true);
    expect(friendKeysCanonical(keys.ownerDeviceId, keys.deviceId, keys.signPublicKey, keys.boxPublicKey, null).toString('utf8').endsWith('\n')).toBe(true);
  });

  it('私信挂到应用账号的凭证原文与签名可验', () => {
    const bind = vectors.socialBind;
    const canonical = socialBindCanonical(bind.accountDeviceId, bind.socialDeviceId);
    expect(canonical.toString('utf8')).toBe(bind.canonical);
    expect(verifyEd25519(ed25519Key(decodeBase64url(vectors.signPublicKey, 32)!), canonical, decodeBase64url(bind.proof, 64)!)).toBe(true);
  });

  it('base64url 只认规范写法', () => {
    expect(decodeBase64url('AA==')).toBeNull();
    expect(decodeBase64url('A+A')).toBeNull();
    expect(decodeBase64url(vectors.deviceId, 16)).not.toBeNull();
    expect(decodeBase64url(vectors.deviceId, 32)).toBeNull();
  });
});

// 节日奖品的信封：客户端 test/festival_test.dart 读同一份文件解开。
const prize = JSON.parse(readFileSync(new URL('./vectors/reward_prize_v1.json', import.meta.url), 'utf8'));

describe('节日奖品的信封向量', () => {
  it('固定的一次性密钥与随机数封出来逐字节一致', () => {
    expect(base64url(x25519PublicOf(x25519PrivateKey(decodeBase64url(prize.deviceSeed, 32)!)))).toBe(prize.devicePublic);
    const sealed = sealRewardPrize(JSON.parse(prize.plaintext), prize.campaign, prize.deviceId, decodeBase64url(prize.devicePublic, 32)!, x25519PrivateKey(decodeBase64url(prize.ephemeralSeed, 32)!), decodeBase64url(prize.nonce, 12)!);
    expect(base64url(sealed)).toBe(prize.sealed);
  });
});

// 第 2 版（带服务器签名，人工决策见 reward_seal.ts 的 11-17 那条）：客户端 test/festival_test.dart 读同一份文件，先验签再解开。
const signedPrize = JSON.parse(readFileSync(new URL('./vectors/reward_prize_v2.json', import.meta.url), 'utf8'));

describe('节日奖品的第 2 版信封向量', () => {
  const serverKey = createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), decodeBase64url(signedPrize.serverSeed, 32)!]), format: 'der', type: 'pkcs8' });
  const signer = (message: Uint8Array) => sign(null, message, serverKey);
  const seal = (campaign = signedPrize.campaign, deviceId = signedPrize.deviceId) =>
    sealSignedRewardPrize(JSON.parse(signedPrize.plaintext), campaign, deviceId, decodeBase64url(signedPrize.devicePublic, 32)!, signer, x25519PrivateKey(decodeBase64url(signedPrize.ephemeralSeed, 32)!), decodeBase64url(signedPrize.nonce, 12)!);

  it('固定的密钥与随机数封出来逐字节一致；末尾 64 字节是服务器对「活动、设备号、前面全部字节」的签名', () => {
    const sealed = seal();
    expect(base64url(sealed)).toBe(signedPrize.sealed);
    expect(sealed[0]).toBe(2);
    const body = sealed.subarray(0, sealed.length - 64);
    const key = ed25519Key(decodeBase64url(signedPrize.serverPublic, 32)!);
    expect(verifyEd25519(key, rewardPrizeCanonical(signedPrize.campaign, signedPrize.deviceId, body), sealed.subarray(sealed.length - 64))).toBe(true);
    expect(verifyEd25519(key, rewardPrizeCanonical(`${signedPrize.campaign}x`, signedPrize.deviceId, body), sealed.subarray(sealed.length - 64)), '别的活动').toBe(false);
    expect(verifyEd25519(key, rewardPrizeCanonical(signedPrize.campaign, 'BBBBBBBBBBBBBBBBBBBBBB', body), sealed.subarray(sealed.length - 64)), '别的设备').toBe(false);
    expect(rewardPrizeCanonical('c', 'd', Buffer.from([1, 2])).equals(Buffer.concat([Buffer.from('SXD1-reward-prize\nc\nd\n', 'utf8'), Buffer.from([1, 2])]))).toBe(true);
  });
});
