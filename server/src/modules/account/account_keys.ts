import { HttpStatus, Injectable } from '@nestjs/common';
import { createDecipheriv, createPrivateKey, createPublicKey, diffieHellman, hkdfSync, KeyObject, randomBytes, scrypt, timingSafeEqual } from 'node:crypto';

import { env } from 'src/config/env';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { passwordHashConcurrency } from 'src/common/relay_limits';
import { decodeBase64url } from 'src/common/crypto/relay_crypto';

const x25519Pkcs8Prefix = Buffer.from('302e020100300506032b656e04220420', 'hex');
const x25519SpkiPrefix = Buffer.from('302a300506032b656e032100', 'hex');

// 封装密码与恢复码的信封，客户端 lib/social/account_seal.dart 与此一致（共用 test/vectors/account_seal_v1.json）：
// 一次性 X25519 与中转公钥协商，HKDF-SHA256（盐 = 一次性公钥 + 中转公钥，info = SXD1-account-sign-in）派生 AES-256-GCM 密钥，
// 附加数据绑定版本、一次性公钥与发起的设备号（别的设备拿去重放解不开；同一设备重放整条请求由请求签名的随机数挡住）。
// 布局：版本(1) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16)。中转是明文 HTTP，密码不加这层就会被同一网络里的人看到。
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

// 密码与恢复码的哈希：Node 自带的 scrypt（N=2^15、r=8、p=1，约 32MB 内存、几十毫秒），每条随机 16 字节盐；
// 存成「scrypt$N$r$p$盐$哈希」，以后调参数旧哈希照样能核对。
const scryptCost = { N: 2 ** 15, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };
const scryptLength = 32;
const derive = (secret: string, salt: Buffer, cost: { N: number; r: number; p: number; maxmem: number }) =>
  new Promise<Buffer>((resolve, reject) => scrypt(secret.normalize('NFC'), salt, scryptLength, cost, (error, key) => (error ? reject(error) : resolve(key))));

// 应用账号的服务器密钥与密码哈希（环境变量见 src/config/env.ts）。
@Injectable()
export class AccountKeys {
  private readonly sealPrivate: KeyObject;
  private readonly sealPublic: Buffer;
  private hashing = 0;

  constructor() {
    const seed = decodeBase64url(env().account.sealKey, 32);
    if (seed === null) throw new Error('RELAY_ACCOUNT_SEAL_KEY 应为 32 字节 base64url');
    this.sealPrivate = x25519PrivateKey(seed);
    this.sealPublic = x25519PublicOf(this.sealPrivate);
  }

  open(sealed: Buffer, deviceId: string) {
    return openAccountSeal(sealed, deviceId, this.sealPrivate, this.sealPublic);
  }

  // 每个实例同时最多 passwordHashConcurrency 个哈希在算（内存有界），超出回 503 让客户端稍后再试。
  private async gate<T>(work: () => Promise<T>) {
    if (this.hashing >= passwordHashConcurrency) throw new RelayError(RelayCode.rateLimited, HttpStatus.SERVICE_UNAVAILABLE, '登录的人太多，请稍后再试', { retryAfter: 5 });
    this.hashing++;
    try {
      return await work();
    } finally {
      this.hashing--;
    }
  }

  hash(secret: string) {
    return this.gate(async () => {
      const salt = randomBytes(16);
      const key = await derive(secret, salt, scryptCost);
      return `scrypt$${scryptCost.N}$${scryptCost.r}$${scryptCost.p}$${salt.toString('base64url')}$${key.toString('base64url')}`;
    });
  }

  verify(secret: string, stored: string) {
    return this.gate(async () => {
      const [kind, n, r, p, salt, key] = stored.split('$');
      if (kind !== 'scrypt' || key === undefined) return false;
      const expected = Buffer.from(key, 'base64url');
      const actual = await derive(secret, Buffer.from(salt, 'base64url'), { N: Number(n), r: Number(r), p: Number(p), maxmem: scryptCost.maxmem });
      return actual.length === expected.length && timingSafeEqual(actual, expected);
    });
  }
}
