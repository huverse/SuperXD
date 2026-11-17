import { readFileSync } from 'node:fs';

import { createPrivateKey, sign } from 'node:crypto';

import { accountDeletedCanonical, base64url, decodeBase64url, deviceIdOf, ed25519Key, friendKeysCanonical, inviteProofCanonical, requestCanonical, rewardPrizeCanonical, socialBindCanonical, verifyEd25519, x25519PrivateKey, x25519PublicOf } from 'src/common/crypto/relay_crypto';
import { sealRewardPrize, sealSignedRewardPrize } from 'src/modules/reward/reward_seal';
import { accountSealKeyId, accountSealKeyOf, openAccountSeal } from 'src/modules/account/account_keys';

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

  it('「账号已注销」的证明原文与服务器签名可验，绑定设备号与这次请求的随机数', () => {
    const deleted = vectors.accountDeleted;
    const canonical = accountDeletedCanonical(deleted.deviceId, deleted.nonce);
    expect(canonical.toString('utf8')).toBe(deleted.canonical);
    const key = ed25519Key(decodeBase64url(deleted.publicKey, 32)!);
    expect(verifyEd25519(key, canonical, decodeBase64url(deleted.proof, 64)!)).toBe(true);
    expect(verifyEd25519(key, accountDeletedCanonical(deleted.deviceId, vectors.request.nonce), decodeBase64url(deleted.proof, 64)!)).toBe(false);
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

// 应用账号的信封（11-17 起第 2 版带钥号，服务器可以同时认几把私钥）：客户端 test/social_protocol_test.dart 用同一份 account_seal_v2.json 逐字节封出来。
const keyedSeal = JSON.parse(readFileSync(new URL('./vectors/account_seal_v2.json', import.meta.url), 'utf8'));
const legacySeal = JSON.parse(readFileSync(new URL('./vectors/account_seal_v1.json', import.meta.url), 'utf8'));

describe('应用账号信封的钥号', () => {
  const current = accountSealKeyOf(decodeBase64url(keyedSeal.recipientSeed, 32)!);
  const next = accountSealKeyOf(Buffer.alloc(32, 0x5a));

  it('第 2 版按钥号挑私钥：几把钥里有它就打得开，换设备号、改钥号、改一个字节、钥不在都打不开', () => {
    expect(base64url(accountSealKeyId(current.publicKey))).toBe(keyedSeal.keyId);
    const sealed = decodeBase64url(keyedSeal.sealed)!;
    expect(sealed[0]).toBe(2);
    expect(base64url(sealed.subarray(1, 9))).toBe(keyedSeal.keyId);
    expect(JSON.parse(openAccountSeal(sealed, keyedSeal.deviceId, [current])!.toString('utf8'))).toEqual(keyedSeal.plaintext);
    expect(JSON.parse(openAccountSeal(sealed, keyedSeal.deviceId, [next, current])!.toString('utf8')), '换钥过渡期新钥在前').toEqual(keyedSeal.plaintext);
    expect(openAccountSeal(sealed, keyedSeal.deviceId, [next]), '服务器不认这把').toBeNull();
    expect(openAccountSeal(sealed, 'BBBBBBBBBBBBBBBBBBBBBB', [current])).toBeNull();
    const renamed = Buffer.from(sealed);
    renamed.set(next.keyId, 1);
    expect(openAccountSeal(renamed, keyedSeal.deviceId, [next, current]), '钥号被改成另一把').toBeNull();
    const tampered = Buffer.from(sealed);
    tampered[70] ^= 1;
    expect(openAccountSeal(tampered, keyedSeal.deviceId, [current])).toBeNull();
    expect(openAccountSeal(Buffer.from([3, ...sealed.subarray(1)]), keyedSeal.deviceId, [current]), '不认识的版本').toBeNull();
  });

  it('第 1 版（旧客户端，没有钥号）逐把试：旧钥还在就打得开，删了就打不开', () => {
    const sealed = decodeBase64url(legacySeal.sealed)!;
    expect(JSON.parse(openAccountSeal(sealed, legacySeal.deviceId, [next, current])!.toString('utf8'))).toEqual(legacySeal.proof);
    expect(openAccountSeal(sealed, legacySeal.deviceId, [next])).toBeNull();
  });
});
