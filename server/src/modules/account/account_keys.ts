import { Injectable } from '@nestjs/common';
import { createDecipheriv, createHmac, createPrivateKey, createPublicKey, diffieHellman, hkdfSync, KeyObject } from 'node:crypto';

import { env } from 'src/config/env';
import { decodeBase64url } from 'src/common/crypto/relay_crypto';

const x25519Pkcs8Prefix = Buffer.from('302e020100300506032b656e04220420', 'hex');
const x25519SpkiPrefix = Buffer.from('302a300506032b656e032100', 'hex');

// 封装口令摘要的信封，客户端 lib/social/account_seal.dart 与此一致（共用 test/vectors/account_seal_v1.json）：
// 一次性 X25519 与中转公钥协商，HKDF-SHA256（盐 = 一次性公钥 + 中转公钥，info = SXD1-account-sign-in）派生 AES-256-GCM 密钥，
// 附加数据绑定版本、一次性公钥与发起的设备号（别的设备拿去重放解不开）。布局：版本(1) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16)。
export const accountSealVersion = 1;
const sealOverhead = 1 + 32 + 12 + 16;

export const openAccountSeal = (sealed: Buffer, deviceId: string, privateKey: KeyObject, publicKey: Buffer): Buffer | null => {
  if (sealed.length <= sealOverhead || sealed[0] !== accountSealVersion) return null;
  const ephemeral = sealed.subarray(1, 33);
  try {
    const shared = diffieHellman({ privateKey, publicKey: createPublicKey({ key: Buffer.concat([x25519SpkiPrefix, ephemeral]), format: 'der', type: 'spki' }) });
    const key = Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeral, publicKey]), 'SXD1-account-sign-in', 32));
    const decipher = createDecipheriv('aes-256-gcm', key, sealed.subarray(33, 45));
    decipher.setAAD(Buffer.concat([Buffer.from([accountSealVersion]), ephemeral, Buffer.from(deviceId, 'utf8')]));
    decipher.setAuthTag(sealed.subarray(sealed.length - 16));
    return Buffer.concat([decipher.update(sealed.subarray(45, sealed.length - 16)), decipher.final()]);
  } catch {
    // 一次性公钥是低阶点、密文被改或不是给这台设备的，一律当打不开。
    return null;
  }
};

export const x25519PrivateKey = (seed: Buffer) => createPrivateKey({ key: Buffer.concat([x25519Pkcs8Prefix, seed]), format: 'der', type: 'pkcs8' });
export const x25519PublicOf = (privateKey: KeyObject) => Buffer.from(createPublicKey(privateKey).export({ format: 'jwk' }).x!, 'base64url');

// 应用账号用到的两把服务器密钥（环境变量见 src/config/env.ts）：打开客户端封装的口令摘要、给学号算 HMAC。
@Injectable()
export class AccountKeys {
  private readonly sealPrivate: KeyObject;
  private readonly sealPublic: Buffer;
  private readonly subjectKey: Buffer;

  constructor() {
    const seed = decodeBase64url(env().account.sealKey, 32);
    if (seed === null) throw new Error('RELAY_ACCOUNT_SEAL_KEY 应为 32 字节 base64url');
    const subjectKey = decodeBase64url(env().account.subjectKey);
    if (subjectKey === null || subjectKey.length < 32) throw new Error('RELAY_ACCOUNT_SUBJECT_KEY 应为至少 32 字节的 base64url');
    this.sealPrivate = x25519PrivateKey(seed);
    this.sealPublic = x25519PublicOf(this.sealPrivate);
    this.subjectKey = subjectKey;
  }

  open(sealed: Buffer, deviceId: string) {
    return openAccountSeal(sealed, deviceId, this.sealPrivate, this.sealPublic);
  }

  // 主体哈希：登录方式与主体（教务是「来源\n学号」）带域前缀做 HMAC；库里只有它，没有密钥认不出是谁。
  subjectHash(provider: string, subject: string) {
    return createHmac('sha256', this.subjectKey).update(`SXD1-subject\n${provider}\n${subject}`, 'utf8').digest('base64url');
  }

  // 限流计数用的主体：同一密钥换个域前缀，Redis 里也不出现学号。
  attemptKey(provider: string, subject: string) {
    return createHmac('sha256', this.subjectKey).update(`SXD1-attempt\n${provider}\n${subject}`, 'utf8').digest('base64url');
  }
}
