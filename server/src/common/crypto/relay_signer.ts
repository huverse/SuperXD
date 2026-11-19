import { Injectable } from '@nestjs/common';
import { createPrivateKey, KeyObject, sign } from 'node:crypto';

import { env } from 'src/config/env';
import { decodeBase64url } from 'src/common/crypto/relay_crypto';

const ed25519Pkcs8Prefix = Buffer.from('302e020100300506032b657004220420', 'hex');

// 服务器的在线签名钥（Ed25519，种子在 .env 的 RELAY_FRIEND_SIGN_KEY，名字沿用最早只签好友公钥时的叫法；开发者本机另存一份）：
// 当初中转是明文 HTTP（11-18 起 HTTPS，8080 明文入口还留给旧版本），会让客户端做重要或不可逆动作的回复由它签名，客户端用内置公钥（lib/relay/relay_client.dart 的 relayServerKeys）验过才用。
// 一把钥签三类原文，各带域前缀，彼此不能挪用（原文都在 relay_crypto.ts）：好友公钥 SXD1-friend-keys（friend_key_signer.ts）、
// 奖品信封 SXD1-reward-prize（reward_seal.ts）、账号已注销 SXD1-account-deleted（account_deleted_proof.ts）。
// [人工决策-2026-11-17 21:24:25] 明文 HTTP 期间只给两类关键回复加服务器认证、不做通用回复签名（用户选定）：奖品信封带服务器签名、「账号已注销」带绑定这次请求的签名，
// 都用这把钥（与好友公钥签名同在服务器 .env，分开两把挡不住同一台服务器被攻破，徒增部署步骤）。只挡网络上的人，挡不住服务器本身。
@Injectable()
export class RelaySigner {
  private readonly key: KeyObject;

  constructor() {
    const seed = decodeBase64url(env().signing.key, 32);
    if (seed === null) throw new Error('RELAY_FRIEND_SIGN_KEY 应为 32 字节 base64url');
    this.key = createPrivateKey({ key: Buffer.concat([ed25519Pkcs8Prefix, seed]), format: 'der', type: 'pkcs8' });
  }

  sign(message: Uint8Array): Buffer {
    return sign(null, message, this.key);
  }
}
