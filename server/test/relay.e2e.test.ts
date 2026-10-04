import { NestExpressApplication } from '@nestjs/platform-express';
import { randomBytes, randomUUID } from 'node:crypto';
import Redis from 'ioredis';
import request from 'supertest';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { REDIS } from 'src/common/redis/redis.module';
import { base64url } from 'src/common/crypto/relay_crypto';
import { RetentionTask } from 'src/modules/pairing/retention.task';
import { createInviteKeys, fakeEnvelope, helloOf, inviteProof, TestDevice } from './test_device';

let app: NestExpressApplication;
let server: ReturnType<NestExpressApplication['getHttpServer']>;
let dataSource: DataSource;

beforeAll(async () => {
  app = await createRelayApp();
  await app.init();
  server = app.getHttpServer();
  dataSource = app.get(DataSource);
  await dataSource.query('DELETE FROM message');
  await dataSource.query('DELETE FROM friendship');
  await dataSource.query('DELETE FROM device');
});

// 测试都从 127.0.0.1 注册，每个用例前清空限流与随机数，互不影响。
beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
});

afterAll(async () => {
  await app.close();
});

const registered = async () => {
  const device = new TestDevice(server);
  const response = await device.register();
  expect(response.status).toBe(200);
  return device;
};

// A 出示二维码，B 扫码：返回兑换响应。
const pair = async (owner: TestDevice, redeemer: TestDevice, hello = helloOf()) => {
  const invite = createInviteKeys();
  expect((await owner.call('POST', '/v1/invites', { inviteId: invite.inviteId, publicKey: invite.publicKey })).status).toBe(200);
  return redeemer.call('POST', '/v1/friends/redeem', { inviteId: invite.inviteId, proof: inviteProof(invite.privateKey, invite.inviteId, redeemer.deviceId), hello });
};

describe('健康检查', () => {
  it('免签名返回协议版本与服务器时间', async () => {
    const response = await request(server).get('/v1/health');
    expect(response.status).toBe(200);
    expect(response.body.protocol).toBe(1);
    expect(Math.abs(response.body.serverTime - Date.now())).toBeLessThan(5000);
  });
});

describe('设备注册与请求签名', () => {
  it('注册幂等，设备号与公钥哈希一致', async () => {
    const device = new TestDevice(server);
    const first = await device.register();
    expect(first.status).toBe(200);
    expect(first.body.deviceId).toBe(device.deviceId);
    expect((await device.register()).status).toBe(200);
  });

  it('同一 IP 每小时最多注册 20 台新设备，已注册的重复注册不计数', async () => {
    const first = await registered();
    for (let index = 1; index < 20; index++) await registered();
    const blocked = await new TestDevice(server).register();
    expect(blocked.status).toBe(429);
    expect(blocked.body.code).toBe('RATE_LIMITED');
    expect(blocked.body.retryAfter).toBeGreaterThan(0);
    expect((await first.register()).status).toBe(200);
  });

  it('设备号与公钥不符时拒绝', async () => {
    const device = new TestDevice(server), other = new TestDevice(server);
    const response = await device.call('POST', '/v1/devices', { signPublicKey: other.signPublicKey, boxPublicKey: device.boxPublicKey });
    expect(response.body.code).toBe('DEVICE_MISMATCH');
  });

  it('签名错误、未注册设备一律 UNAUTHORIZED', async () => {
    const device = await registered();
    const body = Buffer.from('{}');
    const headers = device.headers('GET', '/v1/friends', body);
    // 签名覆盖的是空请求体，篡改路径即验签失败。
    const tampered = await request(server).get('/v1/messages').set(headers);
    expect(tampered.body.code).toBe('UNAUTHORIZED');
    const stranger = new TestDevice(server);
    expect((await stranger.call('GET', '/v1/friends')).body.code).toBe('UNAUTHORIZED');
    expect((await request(server).get('/v1/friends')).body.code).toBe('UNAUTHORIZED');
  });

  it('同一随机数重放被拒', async () => {
    const device = await registered();
    const nonce = base64url(randomBytes(16));
    expect((await device.call('GET', '/v1/friends', undefined, nonce)).status).toBe(200);
    const replay = await device.call('GET', '/v1/friends', undefined, nonce);
    expect(replay.status).toBe(401);
    expect(replay.body.code).toBe('REPLAYED');
  });

  it('时钟偏差超过 5 分钟返回服务器时间', async () => {
    const device = await registered();
    device.clockOffset = -6 * 60 * 1000;
    const response = await device.call('GET', '/v1/friends');
    expect(response.body.code).toBe('CLOCK_SKEW');
    expect(Math.abs(response.body.serverTime - Date.now())).toBeLessThan(5000);
  });
});

describe('扫码加好友', () => {
  it('扫码即互为好友，问候进入邀请人信箱', async () => {
    const owner = await registered(), redeemer = await registered();
    const hello = helloOf();
    const response = await pair(owner, redeemer, hello);
    expect(response.status).toBe(200);
    expect(response.body.deviceId).toBe(owner.deviceId);
    expect((await owner.call('GET', '/v1/friends')).body.friends.map((friend: { deviceId: string }) => friend.deviceId)).toEqual([redeemer.deviceId]);
    expect((await redeemer.call('GET', '/v1/friends')).body.friends.map((friend: { deviceId: string }) => friend.deviceId)).toEqual([owner.deviceId]);
    const inbox = await owner.call('GET', '/v1/messages');
    expect(inbox.body.messages).toHaveLength(1);
    expect(inbox.body.messages[0]).toMatchObject({ from: redeemer.deviceId, envelope: hello.envelope });
  });

  it('有效期内可被多人扫，重复扫不重复建关系', async () => {
    const owner = await registered(), first = await registered(), second = await registered();
    const invite = createInviteKeys();
    await owner.call('POST', '/v1/invites', { inviteId: invite.inviteId, publicKey: invite.publicKey });
    for (const redeemer of [first, second, first]) {
      const response = await redeemer.call('POST', '/v1/friends/redeem', { inviteId: invite.inviteId, proof: inviteProof(invite.privateKey, invite.inviteId, redeemer.deviceId), hello: helloOf() });
      expect(response.status).toBe(200);
    }
    expect((await owner.call('GET', '/v1/friends')).body.friends).toHaveLength(2);
  });

  it('凭证只对扫码方本人有效：截获的凭证换设备使用被拒', async () => {
    const owner = await registered(), redeemer = await registered(), thief = await registered();
    const invite = createInviteKeys();
    await owner.call('POST', '/v1/invites', { inviteId: invite.inviteId, publicKey: invite.publicKey });
    const proof = inviteProof(invite.privateKey, invite.inviteId, redeemer.deviceId);
    const stolen = await thief.call('POST', '/v1/friends/redeem', { inviteId: invite.inviteId, proof, hello: helloOf() });
    expect(stolen.body.code).toBe('INVITE_PROOF_INVALID');
  });

  it('不能扫自己；新建邀请作废旧邀请；作废后不可用', async () => {
    const owner = await registered(), redeemer = await registered();
    const old = createInviteKeys(), fresh = createInviteKeys();
    await owner.call('POST', '/v1/invites', { inviteId: old.inviteId, publicKey: old.publicKey });
    const self = await owner.call('POST', '/v1/friends/redeem', { inviteId: old.inviteId, proof: inviteProof(old.privateKey, old.inviteId, owner.deviceId), hello: helloOf() });
    expect(self.body.code).toBe('INVITE_SELF');
    await owner.call('POST', '/v1/invites', { inviteId: fresh.inviteId, publicKey: fresh.publicKey });
    const stale = await redeemer.call('POST', '/v1/friends/redeem', { inviteId: old.inviteId, proof: inviteProof(old.privateKey, old.inviteId, redeemer.deviceId), hello: helloOf() });
    expect(stale.body.code).toBe('INVITE_NOT_FOUND');
    expect((await owner.call('DELETE', `/v1/invites/${fresh.inviteId}`)).status).toBe(204);
    const revoked = await redeemer.call('POST', '/v1/friends/redeem', { inviteId: fresh.inviteId, proof: inviteProof(fresh.privateKey, fresh.inviteId, redeemer.deviceId), hello: helloOf() });
    expect(revoked.body.code).toBe('INVITE_NOT_FOUND');
  });

  it('好友数达上限时拒绝', async () => {
    const owner = await registered(), redeemer = await registered();
    const now = new Date();
    const rows = Array.from({ length: 500 }, (_, index) => [owner.deviceId, `filler${String(index).padStart(16, '0')}`, now, now]);
    await dataSource.query('INSERT INTO friendship (owner_device_id, peer_device_id, create_time, update_time) VALUES ?', [rows]);
    expect((await pair(owner, redeemer)).body.code).toBe('FRIEND_LIMIT');
    expect((await redeemer.call('GET', '/v1/friends')).body.friends).toHaveLength(0);
  });
});

describe('信箱', () => {
  it('好友之间收发、幂等重发、确认后删除', async () => {
    const alice = await registered(), bob = await registered();
    await pair(alice, bob);
    const clientId = randomUUID(), envelope = fakeEnvelope(1024);
    const sent = await bob.call('POST', '/v1/messages', { to: alice.deviceId, clientId, envelope });
    expect(sent.status).toBe(200);
    const again = await bob.call('POST', '/v1/messages', { to: alice.deviceId, clientId, envelope });
    expect(again.body.id).toBe(sent.body.id);
    const inbox = await alice.call('GET', '/v1/messages');
    // 问候 + 一条消息，重发没有多出一条。
    expect(inbox.body.messages).toHaveLength(2);
    expect(inbox.body.messages[1]).toMatchObject({ id: sent.body.id, from: bob.deviceId, envelope });
    // 别人确认不了我的消息。
    expect((await bob.call('POST', '/v1/messages/ack', { ids: [sent.body.id] })).body.removed).toBe(0);
    const ids = inbox.body.messages.map((message: { id: string }) => message.id);
    expect((await alice.call('POST', '/v1/messages/ack', { ids })).body.removed).toBe(2);
    expect((await alice.call('GET', '/v1/messages')).body.messages).toHaveLength(0);
  });

  it('按游标分页，more 表示还有', async () => {
    const alice = await registered(), bob = await registered();
    await pair(alice, bob);
    for (let index = 0; index < 4; index++) await bob.call('POST', '/v1/messages', { to: alice.deviceId, clientId: randomUUID(), envelope: fakeEnvelope() });
    const first = await alice.call('GET', '/v1/messages?limit=3');
    expect(first.body.messages).toHaveLength(3);
    expect(first.body.more).toBe(true);
    const second = await alice.call('GET', `/v1/messages?after=${first.body.messages[2].id}&limit=3`);
    expect(second.body.messages).toHaveLength(2);
    expect(second.body.more).toBe(false);
  });

  it('非好友、删除好友后拒收', async () => {
    const alice = await registered(), bob = await registered(), carol = await registered();
    await pair(alice, bob);
    expect((await carol.call('POST', '/v1/messages', { to: alice.deviceId, clientId: randomUUID(), envelope: fakeEnvelope() })).body.code).toBe('NOT_FRIEND');
    expect((await alice.call('DELETE', `/v1/friends/${bob.deviceId}`)).status).toBe(204);
    expect((await bob.call('POST', '/v1/messages', { to: alice.deviceId, clientId: randomUUID(), envelope: fakeEnvelope() })).body.code).toBe('NOT_FRIEND');
    expect((await bob.call('GET', '/v1/friends')).body.friends).toHaveLength(0);
  });

  it('密文超过 256KB 拒收', async () => {
    const alice = await registered(), bob = await registered();
    await pair(alice, bob);
    const response = await bob.call('POST', '/v1/messages', { to: alice.deviceId, clientId: randomUUID(), envelope: fakeEnvelope(256 * 1024 + 1) });
    expect(response.status).toBe(413);
    expect(response.body.code).toBe('ENVELOPE_TOO_LARGE');
  });

  it('请求体超过上限也返回 ENVELOPE_TOO_LARGE', async () => {
    const alice = await registered(), bob = await registered();
    await pair(alice, bob);
    const response = await bob.call('POST', '/v1/messages', { to: alice.deviceId, clientId: randomUUID(), envelope: fakeEnvelope(400 * 1024) });
    expect(response.status).toBe(413);
    expect(response.body.code).toBe('ENVELOPE_TOO_LARGE');
  });

  it('对方待收满 1000 条时拒收', async () => {
    const alice = await registered(), bob = await registered();
    await pair(alice, bob);
    const now = new Date(), expire = new Date(Date.now() + 86400000);
    const rows = Array.from({ length: 1000 }, () => [alice.deviceId, bob.deviceId, randomUUID(), Buffer.from('x'), expire, now, now]);
    await dataSource.query('INSERT INTO message (recipient_device_id, sender_device_id, client_id, envelope, expire_time, create_time, update_time) VALUES ?', [rows]);
    expect((await bob.call('POST', '/v1/messages', { to: alice.deviceId, clientId: randomUUID(), envelope: fakeEnvelope() })).body.code).toBe('MAILBOX_FULL');
  });

  it('多余字段与不合法参数被拒', async () => {
    const alice = await registered();
    expect((await alice.call('POST', '/v1/messages', { to: 'x', clientId: randomUUID(), envelope: 'abc' })).body.code).toBe('INVALID_REQUEST');
    expect((await alice.call('GET', '/v1/messages?limit=500')).body.code).toBe('INVALID_REQUEST');
  });
});

describe('关闭私信', () => {
  it('删除本设备连同好友关系与待收消息，之后请求一律 UNAUTHORIZED', async () => {
    const alice = await registered(), bob = await registered();
    await pair(alice, bob);
    expect((await alice.call('DELETE', '/v1/devices')).status).toBe(204);
    expect(await dataSource.query('SELECT id FROM message WHERE recipient_device_id = ?', [alice.deviceId])).toHaveLength(0);
    expect((await bob.call('GET', '/v1/friends')).body.friends).toHaveLength(0);
    expect((await alice.call('GET', '/v1/friends')).body.code).toBe('UNAUTHORIZED');
  });
});

describe('数据保留', () => {
  it('过期消息与长期不活跃设备被清理', async () => {
    const alice = await registered(), bob = await registered();
    await pair(alice, bob);
    await dataSource.query('UPDATE message SET expire_time = ? WHERE recipient_device_id = ?', [new Date(Date.now() - 1000), alice.deviceId]);
    await dataSource.query('UPDATE device SET last_seen_time = ? WHERE device_id = ?', [new Date(Date.now() - 401 * 86400000), bob.deviceId]);
    await app.get(RetentionTask).sweep();
    expect(await dataSource.query('SELECT id FROM message WHERE recipient_device_id = ?', [alice.deviceId])).toHaveLength(0);
    expect(await dataSource.query('SELECT id FROM device WHERE device_id = ?', [bob.deviceId])).toHaveLength(0);
    expect((await alice.call('GET', '/v1/friends')).body.friends).toHaveLength(0);
  });
});
