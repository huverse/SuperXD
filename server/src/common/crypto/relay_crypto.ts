import { createHash, createPublicKey, KeyObject, verify } from 'node:crypto';

// 协议 v1 的密码学约定，客户端 lib/social/social_crypto.dart 与此逐字节一致（双端共用 test/vectors 下的测试向量）。
// 设备身份：Ed25519 签名公钥；设备号 = base64url(sha256(签名公钥) 前 16 字节)，22 个字符。

const ed25519SpkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');

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

export const verifyEd25519 = (key: KeyObject, message: Uint8Array, signature: Uint8Array) => signature.length === 64 && verify(null, message, key, signature);

// 请求签名原文：版本、方法、路径（含查询串）、毫秒时间戳、随机数、请求体 sha256，换行分隔。
export const requestCanonical = (method: string, pathWithQuery: string, time: string, nonce: string, body: Uint8Array) =>
  Buffer.from(['SXD1', method.toUpperCase(), pathWithQuery, time, nonce, base64url(sha256(body))].join('\n'), 'utf8');

// 邀请凭证原文：扫码方用二维码里的邀请私钥签“邀请号 + 自己的设备号”，凭证只对扫码方本人有效，被截获也不能给别的设备用。
export const inviteProofCanonical = (inviteId: string, redeemerDeviceId: string) => Buffer.from(['SXD1-invite', inviteId, redeemerDeviceId].join('\n'), 'utf8');
