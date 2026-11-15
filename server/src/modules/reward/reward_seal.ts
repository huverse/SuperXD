import { createCipheriv, diffieHellman, generateKeyPairSync, hkdfSync, KeyObject, randomBytes } from 'node:crypto';

import { x25519PublicKey, x25519PublicOf } from 'src/common/crypto/relay_crypto';

// 奖品下发的信封（客户端 lib/social/relay_reward_client.dart 的 openRewardPrize 与此一致，共用 test/vectors/reward_prize_v1.json）：
// 中转是明文 HTTP，支付宝口令与二维码是真钱，不加这层同一网络里的人就能截走。只有抽签的那台设备打得开：
// 一次性 X25519 与这台设备登记的 box 公钥协商，HKDF-SHA256（盐 = 一次性公钥 + 设备公钥，info = SXD1-reward-prize）派生 AES-256-GCM 密钥，
// 附加数据绑定版本、一次性公钥与「活动编号\n设备号」。布局同应用账号的信封：版本(1) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16)。
// 明文是 {kind, content, note} 的 UTF-8 JSON。同一个人重复抽返回同一份奖品，每次都另起一次性密钥重新封。
export const rewardSealVersion = 1;

export const sealRewardPrize = (
  prize: { kind: string; content: string; note: string },
  campaign: string,
  deviceId: string,
  devicePublic: Buffer,
  ephemeral: KeyObject = generateKeyPairSync('x25519').privateKey,
  nonce: Buffer = randomBytes(12),
): Buffer => {
  const ephemeralPublic = x25519PublicOf(ephemeral);
  const shared = diffieHellman({ privateKey: ephemeral, publicKey: x25519PublicKey(devicePublic) });
  const key = Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeralPublic, devicePublic]), 'SXD1-reward-prize', 32));
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.concat([Buffer.from([rewardSealVersion]), ephemeralPublic, Buffer.from(`${campaign}\n${deviceId}`, 'utf8')]));
  const body = Buffer.concat([cipher.update(JSON.stringify({ kind: prize.kind, content: prize.content, note: prize.note }), 'utf8'), cipher.final()]);
  return Buffer.concat([Buffer.from([rewardSealVersion]), ephemeralPublic, nonce, body, cipher.getAuthTag()]);
};
