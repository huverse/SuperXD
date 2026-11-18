import { HttpStatus, Injectable } from '@nestjs/common';
import { createDecipheriv, diffieHellman, hkdfSync, KeyObject, randomBytes, scrypt, timingSafeEqual } from 'node:crypto';

import { env } from 'src/config/env';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { passwordHashConcurrency } from 'src/common/relay_limits';
import { decodeBase64url, sha256, x25519PrivateKey, x25519PublicKey, x25519PublicOf } from 'src/common/crypto/relay_crypto';


// 封装密码与恢复码的信封，客户端 lib/relay/account_seal.dart 与此一致（共用 test/vectors/account_seal_v1.json 与 account_seal_v2.json）：
// 一次性 X25519 与中转公钥协商，HKDF-SHA256（盐 = 一次性公钥 + 中转公钥，info = SXD1-account-sign-in）派生 AES-256-GCM 密钥，
// 附加数据绑定版本、（第 2 版另有钥号）、一次性公钥与发起的设备号（别的设备拿去重放解不开；同一设备重放整条请求由请求签名的随机数挡住）。
// 第 1 版：版本(1) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16)。中转是明文 HTTP，密码不加这层就会被同一网络里的人看到。
// 第 2 版（11-17 起的客户端）：版本(1) | 钥号(8) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16)；钥号是中转公钥 sha256 的前 8 字节（accountSealKeyId），
// 服务器按它挑私钥，于是可以同时认几把、换钥不断旧客户端：先把新钥加进 RELAY_ACCOUNT_SEAL_KEY（逗号分隔，最多 accountSealKeyMax 把），
// 再发内置新公钥的客户端，等旧客户端都低于最低可用版本再从服务器删掉旧钥（步骤见 README「部署」应用账号一条）。
// 第 1 版没有钥号，按服务器认的每一把逐个试（GCM 标签只对得上加密用的那一把），所以只要旧钥还在，11-17 以前的客户端照旧能用。
export const accountSealVersion = 1;
export const accountSealKeyedVersion = 2;
export const accountSealKeyMax = 4;
const keyIdLength = 8;

export type AccountSealKey = { keyId: Buffer; privateKey: KeyObject; publicKey: Buffer };

export const accountSealKeyId = (publicKey: Uint8Array) => sha256(publicKey).subarray(0, keyIdLength);

export const accountSealKeyOf = (seed: Uint8Array): AccountSealKey => {
  const privateKey = x25519PrivateKey(seed);
  const publicKey = x25519PublicOf(privateKey);
  return { keyId: accountSealKeyId(publicKey), privateKey, publicKey };
};

const openWith = (version: number, header: Buffer, sealed: Buffer, deviceId: string, key: AccountSealKey): Buffer | null => {
  const ephemeral = sealed.subarray(header.length, header.length + 32);
  const body = sealed.subarray(header.length + 32);
  try {
    const shared = diffieHellman({ privateKey: key.privateKey, publicKey: x25519PublicKey(ephemeral) });
    const derived = Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeral, key.publicKey]), 'SXD1-account-sign-in', 32));
    const decipher = createDecipheriv('aes-256-gcm', derived, body.subarray(0, 12));
    decipher.setAAD(Buffer.concat([header, ephemeral, Buffer.from(deviceId, 'utf8')]));
    decipher.setAuthTag(body.subarray(body.length - 16));
    return Buffer.concat([decipher.update(body.subarray(12, body.length - 16)), decipher.final()]);
  } catch {
    // 一次性公钥是低阶点、密文被改、不是给这台设备的或不是这把钥封的，一律当打不开。
    return null;
  }
};

// keys 是服务器认的全部中转私钥（第一把是现用的）；打不开返回 null。
export const openAccountSeal = (sealed: Buffer, deviceId: string, keys: readonly AccountSealKey[]): Buffer | null => {
  if (sealed[0] === accountSealVersion && sealed.length > 1 + 32 + 12 + 16) {
    for (const key of keys) {
      const plain = openWith(accountSealVersion, sealed.subarray(0, 1), sealed, deviceId, key);
      if (plain !== null) return plain;
    }
    return null;
  }
  if (sealed[0] !== accountSealKeyedVersion || sealed.length <= 1 + keyIdLength + 32 + 12 + 16) return null;
  const header = sealed.subarray(0, 1 + keyIdLength);
  const key = keys.find((candidate) => candidate.keyId.equals(header.subarray(1)));
  return key === undefined ? null : openWith(accountSealKeyedVersion, header, sealed, deviceId, key);
};


// 密码与恢复码的哈希：Node 自带的 scrypt（N=2^15、r=8、p=1，约 32MB 内存、几十毫秒），每条随机 16 字节盐；
// 存成「scrypt$N$r$p$盐$哈希」，以后调参数旧哈希照样能核对。
const scryptCost = { N: 2 ** 15, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };
const scryptLength = 32;
const derive = (secret: string, salt: Buffer, cost: { N: number; r: number; p: number; maxmem: number }) =>
  new Promise<Buffer>((resolve, reject) => scrypt(secret.normalize('NFC'), salt, scryptLength, cost, (error, key) => (error ? reject(error) : resolve(key))));

// 应用账号的服务器密钥与密码哈希（环境变量见 src/config/env.ts）。
@Injectable()
export class AccountKeys {
  private readonly sealKeys: AccountSealKey[];
  private hashing = 0;

  // RELAY_ACCOUNT_SEAL_KEY 是一把或几把（逗号分隔、现用的在前、最多 accountSealKeyMax 把）X25519 私钥种子，换钥过渡期新旧两把都在。
  constructor() {
    const seeds = env().account.sealKeys;
    if (seeds.length === 0 || seeds.length > accountSealKeyMax) throw new Error(`RELAY_ACCOUNT_SEAL_KEY 应为 1 到 ${accountSealKeyMax} 把，逗号分隔`);
    this.sealKeys = seeds.map((text) => {
      const seed = decodeBase64url(text, 32);
      if (seed === null) throw new Error('RELAY_ACCOUNT_SEAL_KEY 的每一把都应为 32 字节 base64url');
      return accountSealKeyOf(seed);
    });
    if (new Set(this.sealKeys.map((key) => key.keyId.toString('hex'))).size !== this.sealKeys.length) throw new Error('RELAY_ACCOUNT_SEAL_KEY 有重复的钥');
  }

  open(sealed: Buffer, deviceId: string) {
    return openAccountSeal(sealed, deviceId, this.sealKeys);
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
