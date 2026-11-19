import { createHash, createPrivateKey, createPublicKey, KeyObject, verify } from 'node:crypto';

// 协议 v1 的密码学约定，客户端 lib/relay/relay_crypto.dart（签名请求与设备身份）与 lib/social/social_crypto.dart（私信信封与凭证）与此逐字节一致（双端共用 test/vectors 下的测试向量）。
// 设备身份：Ed25519 签名公钥；设备号 = base64url(sha256(签名公钥) 前 16 字节)，22 个字符。

const ed25519SpkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');
const x25519Pkcs8Prefix = Buffer.from('302e020100300506032b656e04220420', 'hex');
const x25519SpkiPrefix = Buffer.from('302a300506032b656e032100', 'hex');

export const base64url = (bytes: Uint8Array) => Buffer.from(bytes).toString('base64url');

// 只接受规范 base64url（无填充）；长度不符返回 null，由调用方报 INVALID_REQUEST。
export const decodeBase64url = (text: string, length?: number): Buffer | null => {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return null;
  const bytes = Buffer.from(text, 'base64url');
  if (bytes.toString('base64url') !== text) return null;
  if (length !== undefined && bytes.length !== length) return null;
  return bytes;
};

export const sha256 = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest();

export const deviceIdOf = (signPublicKey: Uint8Array) => base64url(sha256(signPublicKey).subarray(0, 16));

export const ed25519Key = (raw: Uint8Array): KeyObject => createPublicKey({ key: Buffer.concat([ed25519SpkiPrefix, raw]), format: 'der', type: 'spki' });

// X25519 的原始 32 字节私钥种子与公钥换成 Node 的 KeyObject（应用账号的信封与节日奖品的信封共用）。
export const x25519PrivateKey = (seed: Uint8Array) => createPrivateKey({ key: Buffer.concat([x25519Pkcs8Prefix, seed]), format: 'der', type: 'pkcs8' });
export const x25519PublicKey = (raw: Uint8Array): KeyObject => createPublicKey({ key: Buffer.concat([x25519SpkiPrefix, raw]), format: 'der', type: 'spki' });
export const x25519PublicOf = (privateKey: KeyObject) => Buffer.from(createPublicKey(privateKey).export({ format: 'jwk' }).x!, 'base64url');

export const verifyEd25519 = (key: KeyObject, message: Uint8Array, signature: Uint8Array) => signature.length === 64 && verify(null, message, key, signature);

// 请求签名原文：版本、方法、路径（含查询串）、毫秒时间戳、随机数、请求体 sha256，换行分隔。
export const requestCanonical = (method: string, pathWithQuery: string, time: string, nonce: string, body: Uint8Array) =>
  Buffer.from(['SXD1', method.toUpperCase(), pathWithQuery, time, nonce, base64url(sha256(body))].join('\n'), 'utf8');

// 邀请凭证原文：扫码方用二维码里的邀请私钥签“邀请号 + 自己的设备号”，凭证只对扫码方本人有效，被截获也不能给别的设备用。
export const inviteProofCanonical = (inviteId: string, redeemerDeviceId: string) => Buffer.from(['SXD1-invite', inviteId, redeemerDeviceId].join('\n'), 'utf8');

// 私信设备挂到应用账号的凭证原文：私信密钥对「应用账号那把设备密钥的设备号 + 私信设备号」签名，证明两把钥匙在同一台手机上（客户端 lib/social/social_crypto.dart 同一份）。
export const socialBindCanonical = (accountDeviceId: string, socialDeviceId: string) => Buffer.from(['SXD1-social-bind', accountDeviceId, socialDeviceId].join('\n'), 'utf8');

// 服务器给好友公钥的签名原文（客户端 lib/social/social_crypto.dart 的 friendKeysCanonical 同一份）：好友列表里带的公钥（换了设备的好友、新手机接管拿名单）
// 只由服务器转交，当初中转是明文 HTTP、同一网络里的人能把公钥换成自己的（11-18 起 HTTPS 后照旧签，8080 明文入口上的旧版本仍靠它）；服务器用在线签名钥签「谁问的、好友设备号、两把公钥、认得的旧设备号」，
// 客户端用内置公钥验过才收（人工决策见 src/modules/friend/friend_key_signer.ts）。
export const friendKeysCanonical = (ownerDeviceId: string, deviceId: string, signPublicKey: string, boxPublicKey: string, movedFrom: string | null) =>
  Buffer.from(['SXD1-friend-keys', ownerDeviceId, deviceId, signPublicKey, boxPublicKey, movedFrom ?? ''].join('\n'), 'utf8');

// 服务器给奖品信封的签名原文（第 2 版信封，见 src/modules/reward/reward_seal.ts；客户端 lib/relay/relay_crypto.dart 同一份）：
// 域前缀、活动编号、抽签的设备号各占一行，后面接信封签名前的全部字节。绑定活动与设备，别的活动、别的设备拿去用验不过。
export const rewardPrizeCanonical = (campaign: string, deviceId: string, sealed: Uint8Array) =>
  Buffer.concat([Buffer.from(['SXD1-reward-prize', campaign, deviceId, ''].join('\n'), 'utf8'), sealed]);

// 服务器证明「这把设备密钥所在的应用账号已注销」的签名原文（见 src/modules/account/account_deleted_proof.ts；客户端同一份）：
// 绑定设备号与这次请求的随机数（x-sxd-nonce，客户端每次新起），截下来的旧证明换一次请求就验不过，挡住重放。
export const accountDeletedCanonical = (deviceId: string, nonce: string) => Buffer.from(['SXD1-account-deleted', deviceId, nonce].join('\n'), 'utf8');
