import { createHash, generateKeyPairSync, KeyObject, randomBytes, randomUUID, sign } from 'node:crypto';
import request from 'supertest';

import { base64url, inviteProofCanonical, requestCanonical } from 'src/common/crypto/relay_crypto';

// 测试用设备：持有 Ed25519 签名密钥与 X25519 加密公钥，按协议 v1 给每个请求签名。
export class TestDevice {
  readonly signPrivate: KeyObject;
  readonly signPublicKey: string;
  readonly boxPublicKey: string;
  readonly deviceId: string;
  // 用于模拟时钟偏差。
  clockOffset = 0;

  constructor(private readonly server: Parameters<typeof request>[0]) {
    const pair = generateKeyPairSync('ed25519');
    this.signPrivate = pair.privateKey;
    this.signPublicKey = pair.publicKey.export({ format: 'jwk' }).x!;
    this.boxPublicKey = generateKeyPairSync('x25519').publicKey.export({ format: 'jwk' }).x!;
    this.deviceId = base64url(createHash('sha256').update(Buffer.from(this.signPublicKey, 'base64url')).digest().subarray(0, 16));
  }

  headers(method: string, path: string, body: Buffer, nonce = base64url(randomBytes(16))) {
    const time = String(Date.now() + this.clockOffset);
    const signature = sign(null, requestCanonical(method, path, time, nonce, body), this.signPrivate);
    return { 'x-sxd-device': this.deviceId, 'x-sxd-time': time, 'x-sxd-nonce': nonce, 'x-sxd-signature': base64url(signature), 'content-type': 'application/json' };
  }

  call(method: 'GET' | 'POST' | 'DELETE', path: string, payload?: unknown, nonce?: string) {
    const body = payload === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(payload));
    const agent = request(this.server);
    const pending = method === 'GET' ? agent.get(path) : method === 'POST' ? agent.post(path) : agent.delete(path);
    pending.set(this.headers(method, path, body, nonce));
    return payload === undefined ? pending : pending.send(body.toString());
  }

  register() {
    return this.call('POST', '/v1/devices', { signPublicKey: this.signPublicKey, boxPublicKey: this.boxPublicKey });
  }
}

export const createInviteKeys = () => {
  const pair = generateKeyPairSync('ed25519');
  return { inviteId: base64url(randomBytes(16)), privateKey: pair.privateKey, publicKey: pair.publicKey.export({ format: 'jwk' }).x! };
};

export const inviteProof = (privateKey: KeyObject, inviteId: string, redeemerDeviceId: string) => base64url(sign(null, inviteProofCanonical(inviteId, redeemerDeviceId), privateKey));

export const fakeEnvelope = (size = 64) => base64url(randomBytes(size));

export const helloOf = () => ({ clientId: randomUUID(), envelope: fakeEnvelope() });
