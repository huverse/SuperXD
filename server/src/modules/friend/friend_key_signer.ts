import { Injectable } from '@nestjs/common';
import { createPrivateKey, KeyObject, sign } from 'node:crypto';

import { env } from 'src/config/env';
import { base64url, decodeBase64url, friendKeysCanonical } from 'src/common/crypto/relay_crypto';

const ed25519Pkcs8Prefix = Buffer.from('302e020100300506032b657004220420', 'hex');

// [人工决策-2026-11-15 19:18:31] 换手机接管私信时好友拿到的新公钥由服务器签名（用户选「服务器签名新公钥」，没选「中转改 HTTPS」，另开一轮）：
// 好友列表里带的公钥（换了设备的好友总带，keys=1 时每个都带）都签，原文见 relay_crypto.ts 的 friendKeysCanonical；只挡网络上的人，挡不住服务器本身。
// 私钥种子在 .env 的 RELAY_FRIEND_SIGN_KEY（开发者本机另存一份），公钥写死在客户端 lib/social/relay_client.dart 的 relayFriendKeys（可以列几把，换钥时先加新的）。
@Injectable()
export class FriendKeySigner {
  private readonly key: KeyObject;

  constructor() {
    const seed = decodeBase64url(env().friend.signKey, 32);
    if (seed === null) throw new Error('RELAY_FRIEND_SIGN_KEY 应为 32 字节 base64url');
    this.key = createPrivateKey({ key: Buffer.concat([ed25519Pkcs8Prefix, seed]), format: 'der', type: 'pkcs8' });
  }

  sign(ownerDeviceId: string, deviceId: string, signPublicKey: string, boxPublicKey: string, movedFrom: string | null) {
    return base64url(sign(null, friendKeysCanonical(ownerDeviceId, deviceId, signPublicKey, boxPublicKey, movedFrom), this.key));
  }
}
