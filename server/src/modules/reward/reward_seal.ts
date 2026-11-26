import { createCipheriv, diffieHellman, generateKeyPairSync, hkdfSync, KeyObject, randomBytes } from 'node:crypto';

import { rewardPrizeCanonical, x25519PublicKey, x25519PublicOf } from 'src/common/crypto/relay_crypto';

// 奖品下发的信封（客户端 lib/relay/relay_reward_client.dart 的 openRewardPrize 与此一致，共用 test/vectors/reward_prize_v1.json 与 reward_prize_v2.json）：
// 支付宝口令与二维码是真钱：当初中转是明文 HTTP，不加这层同一网络里的人就能截走；11-18 起 HTTPS、11-26 关掉 8080 明文入口后照旧封装。只有抽签的那台设备打得开：
// 一次性 X25519 与这台设备登记的 box 公钥协商，HKDF-SHA256（盐 = 一次性公钥 + 设备公钥，info = SXD1-reward-prize）派生 AES-256-GCM 密钥，
// 附加数据绑定版本、一次性公钥与「活动编号\n设备号」。布局同应用账号的信封：版本(1) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16)。
// 明文是 {kind, content, note} 的 UTF-8 JSON。同一个人重复抽返回同一份奖品，每次都另起一次性密钥重新封。
// [人工决策-2026-11-17 21:24:25] 奖品信封加服务器认证（用户选「只给两类关键回复加认证」）：第 1 版只保密、不证明是服务器发的
// （box 公钥是公开的，同一网络里的人能把「没抽中」改成「抽中」、塞进自己的口令或二维码）。第 2 版在第 1 版的字节后接服务器签名(64)：
// Ed25519（src/common/crypto/relay_signer.ts 那把在线签名钥），原文是 relay_crypto.ts 的 rewardPrizeCanonical（活动编号、设备号与签名前的全部字节），
// 客户端先验签再解密，验不过当领取失败、不显示内容。新客户端在抽签请求体里带 seal: 2（请求有设备签名，网络上的人去不掉），只认第 2 版；
// 没带的（11-17 以前的客户端；已发布的版本节日登记表都是空的、也不认信里的红包，实际抽不了）照旧给第 1 版。
export const rewardSealVersion = 1;
export const rewardSignedSealVersion = 2;

const seal = (
  version: number,
  prize: { kind: string; content: string; note: string },
  campaign: string,
  deviceId: string,
  devicePublic: Buffer,
  ephemeral: KeyObject,
  nonce: Buffer,
): Buffer => {
  const ephemeralPublic = x25519PublicOf(ephemeral);
  const shared = diffieHellman({ privateKey: ephemeral, publicKey: x25519PublicKey(devicePublic) });
  const key = Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeralPublic, devicePublic]), 'SXD1-reward-prize', 32));
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.concat([Buffer.from([version]), ephemeralPublic, Buffer.from(`${campaign}\n${deviceId}`, 'utf8')]));
  const body = Buffer.concat([cipher.update(JSON.stringify({ kind: prize.kind, content: prize.content, note: prize.note }), 'utf8'), cipher.final()]);
  return Buffer.concat([Buffer.from([version]), ephemeralPublic, nonce, body, cipher.getAuthTag()]);
};

// 第 1 版：只给没带 seal: 2 的旧客户端。
export const sealRewardPrize = (
  prize: { kind: string; content: string; note: string },
  campaign: string,
  deviceId: string,
  devicePublic: Buffer,
  ephemeral: KeyObject = generateKeyPairSync('x25519').privateKey,
  nonce: Buffer = randomBytes(12),
): Buffer => seal(rewardSealVersion, prize, campaign, deviceId, devicePublic, ephemeral, nonce);

// 第 2 版：第 1 版的布局（版本字节为 2）后接服务器签名(64)。sign 是服务器在线签名钥（测试与向量里换成测试钥）。
export const sealSignedRewardPrize = (
  prize: { kind: string; content: string; note: string },
  campaign: string,
  deviceId: string,
  devicePublic: Buffer,
  sign: (message: Uint8Array) => Buffer,
  ephemeral: KeyObject = generateKeyPairSync('x25519').privateKey,
  nonce: Buffer = randomBytes(12),
): Buffer => {
  const sealed = seal(rewardSignedSealVersion, prize, campaign, deviceId, devicePublic, ephemeral, nonce);
  return Buffer.concat([sealed, sign(rewardPrizeCanonical(campaign, deviceId, sealed))]);
};
