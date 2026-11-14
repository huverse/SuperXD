import { NestExpressApplication } from '@nestjs/platform-express';
import { randomBytes } from 'node:crypto';
import Redis from 'ioredis';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { REDIS } from 'src/common/redis/redis.module';
import { createInviteKeys, fakeEnvelope, helloOf, inviteProof, socialBindBody, TestDevice } from './test_device';

// 私信挂到应用账号与换手机接管（人工决策见客户端 lib/social/social_service.dart 文件头）。
let app: NestExpressApplication;
let server: string;
let dataSource: DataSource;

beforeAll(async () => {
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  dataSource = app.get(DataSource);
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
});

afterAll(async () => {
  await app.close();
});

type Friend = { deviceId: string; since: number; signPublicKey?: string; boxPublicKey?: string; movedFrom?: string };

const registered = async () => {
  const device = new TestDevice(server);
  expect((await device.register()).status).toBe(200);
  return device;
};

// 一把登录了应用账号的设备密钥（账号登录本身在 account.e2e.test.ts 测）；给 accountId 就登录到已有的账号（同一个人的另一台手机）。
const signedIn = async (accountId = randomBytes(16).toString('base64url')) => {
  const device = await registered();
  const now = new Date();
  await dataSource.query('INSERT IGNORE INTO app_account (account_id, last_seen_time, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, now, now, now]);
  await dataSource.query('INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, device.deviceId, now, now]);
  return { device, accountId };
};

const bind = (account: TestDevice, social: TestDevice, takeover?: boolean) => account.call('POST', '/v1/account/social', socialBindBody(social, account.deviceId, takeover));

const pair = async (owner: TestDevice, redeemer: TestDevice) => {
  const invite = createInviteKeys();
  expect((await owner.call('POST', '/v1/invites', { inviteId: invite.inviteId, publicKey: invite.publicKey })).status).toBe(200);
  expect((await redeemer.call('POST', '/v1/friends/redeem', { inviteId: invite.inviteId, proof: inviteProof(invite.privateKey, invite.inviteId, redeemer.deviceId), hello: helloOf() })).status).toBe(200);
};

const friendsOf = async (device: TestDevice, keys = false) => (await device.call('GET', keys ? '/v1/friends?keys=1' : '/v1/friends')).body.friends as Friend[];
const boundDevice = async (accountId: string) => ((await dataSource.query('SELECT device_id AS deviceId FROM account_social WHERE account_id = ?', [accountId])) as { deviceId: string }[])[0]?.deviceId;

describe('私信挂到应用账号', () => {
  it('账号还没有私信设备时挂上（没注册过的私信设备顺带登记），重复挂幂等；好友列表照常', async () => {
    const { device: account, accountId } = await signedIn();
    const social = new TestDevice(server);
    const first = await bind(account, social);
    expect(first.status).toBe(200);
    expect(first.body).toEqual({ deviceId: social.deviceId, moved: false });
    expect(await boundDevice(accountId)).toBe(social.deviceId);
    expect((await bind(account, social)).body).toEqual({ deviceId: social.deviceId, moved: false });
    expect((await social.call('GET', '/v1/friends')).status).toBe(200);
  });

  it('凭证不对、没登录应用账号、拿应用账号的密钥当私信设备都不行；一台私信设备不能挂两个账号', async () => {
    const { device: account } = await signedIn();
    const social = await registered(), stranger = await registered();
    const forged = { ...socialBindBody(social, account.deviceId), proof: socialBindBody(social, stranger.deviceId).proof };
    expect((await account.call('POST', '/v1/account/social', forged)).body.code).toBe('INVALID_REQUEST');
    expect((await bind(stranger, social)).body.code).toBe('ACCOUNT_NOT_FOUND');
    expect((await bind(account, account)).body.code).toBe('INVALID_REQUEST');
    const { device: other } = await signedIn();
    expect((await bind(account, social)).status).toBe(200);
    const taken = await bind(other, social);
    expect(taken.status).toBe(409);
    expect(taken.body.code).toBe('SOCIAL_TAKEN');
  });

  it('换手机：没带接管回 SOCIAL_ELSEWHERE；接管后好友关系改挂新设备，好友那边看到新公钥与旧号，确认后不再提示；旧设备与它没收的信删掉', async () => {
    const { device: oldAccount, accountId } = await signedIn();
    const oldSocial = new TestDevice(server);
    expect((await bind(oldAccount, oldSocial)).status).toBe(200);
    const friend = await registered();
    await pair(friend, oldSocial);
    // 好友发给旧手机、旧手机还没收的信。
    expect((await friend.call('POST', '/v1/messages', { to: oldSocial.deviceId, clientId: '00000000-0000-4000-8000-000000000001', envelope: fakeEnvelope() })).status).toBe(200);

    const { device: newAccount } = await signedIn(accountId);
    const newSocial = new TestDevice(server);
    const elsewhere = await bind(newAccount, newSocial);
    expect(elsewhere.status).toBe(409);
    expect(elsewhere.body.code).toBe('SOCIAL_ELSEWHERE');
    expect(await boundDevice(accountId)).toBe(oldSocial.deviceId);

    expect((await bind(newAccount, newSocial, true)).body).toEqual({ deviceId: newSocial.deviceId, moved: true });
    expect(await boundDevice(accountId)).toBe(newSocial.deviceId);
    expect(await friendsOf(friend)).toEqual([expect.objectContaining({ deviceId: newSocial.deviceId, movedFrom: oldSocial.deviceId, signPublicKey: newSocial.signPublicKey, boxPublicKey: newSocial.boxPublicKey })]);
    // 新手机：不带 keys 时没换设备的好友不带公钥，带了每个都有。
    expect(await friendsOf(newSocial)).toEqual([{ deviceId: friend.deviceId, since: expect.any(Number) }]);
    expect(await friendsOf(newSocial, true)).toEqual([expect.objectContaining({ deviceId: friend.deviceId, signPublicKey: friend.signPublicKey, boxPublicKey: friend.boxPublicKey })]);
    expect((await newSocial.call('GET', '/v1/messages')).body.messages).toEqual([]);
    expect((await oldSocial.call('GET', '/v1/messages')).status).toBe(401);
    expect((await dataSource.query('SELECT COUNT(*) AS count FROM message WHERE recipient_device_id = ?', [oldSocial.deviceId]))[0].count).toBe('0');
    // 好友照常能发给新设备；发给旧设备是不是好友。
    expect((await friend.call('POST', '/v1/messages', { to: newSocial.deviceId, clientId: '00000000-0000-4000-8000-000000000002', envelope: fakeEnvelope() })).status).toBe(200);
    expect((await friend.call('POST', '/v1/messages', { to: oldSocial.deviceId, clientId: '00000000-0000-4000-8000-000000000003', envelope: fakeEnvelope() })).body.code).toBe('NOT_FRIEND');

    expect((await friend.call('POST', '/v1/friends/moves/ack', { deviceIds: [newSocial.deviceId] })).status).toBe(204);
    expect(await friendsOf(friend)).toEqual([{ deviceId: newSocial.deviceId, since: expect.any(Number) }]);
  });

  it('旧手机再接管回来：用原来的私信密钥重新挂上；好友还没处理的提示清掉（认得的就是它），处理过的提示指回旧号', async () => {
    const { device: phoneA, accountId } = await signedIn();
    const socialA = new TestDevice(server);
    expect((await bind(phoneA, socialA)).status).toBe(200);
    const slow = await registered(), quick = await registered();
    await pair(slow, socialA);
    await pair(quick, socialA);
    const { device: phoneB } = await signedIn(accountId);
    const socialB = new TestDevice(server);
    expect((await bind(phoneB, socialB, true)).body.moved).toBe(true);
    expect((await quick.call('POST', '/v1/friends/moves/ack', { deviceIds: [socialB.deviceId] })).status).toBe(204);

    expect((await bind(phoneA, socialA)).body.code).toBe('SOCIAL_ELSEWHERE');
    expect((await bind(phoneA, socialA, true)).body).toEqual({ deviceId: socialA.deviceId, moved: true });
    expect(await friendsOf(slow)).toEqual([{ deviceId: socialA.deviceId, since: expect.any(Number) }]);
    expect(await friendsOf(quick)).toEqual([expect.objectContaining({ deviceId: socialA.deviceId, movedFrom: socialB.deviceId })]);
    expect((await socialB.call('GET', '/v1/friends')).status).toBe(401);
  });

  it('两台手机原来各有好友：接管后合在一起，共同好友不重复，两台手机互加的好友关系去掉', async () => {
    const { device: phoneA, accountId } = await signedIn();
    const socialA = await registered(), socialB = await registered();
    const common = await registered(), onlyA = await registered(), onlyB = await registered();
    await pair(common, socialA);
    await pair(onlyA, socialA);
    await pair(common, socialB);
    await pair(onlyB, socialB);
    await pair(socialA, socialB);
    expect((await bind(phoneA, socialA)).status).toBe(200);
    const { device: phoneB } = await signedIn(accountId);
    expect((await bind(phoneB, socialB, true)).body.moved).toBe(true);
    expect((await friendsOf(socialB)).map((friend) => friend.deviceId).sort()).toEqual([common.deviceId, onlyA.deviceId, onlyB.deviceId].sort());
    // 共同好友本来就认得 B，不提示；只认得 A 的提示换了设备。
    expect(await friendsOf(common)).toEqual([{ deviceId: socialB.deviceId, since: expect.any(Number) }]);
    expect(await friendsOf(onlyA)).toEqual([expect.objectContaining({ deviceId: socialB.deviceId, movedFrom: socialA.deviceId })]);
  });

  it('注销应用账号：私信设备连同好友关系与信箱一起删；关闭私信删设备时挂的登记一起删、之后能重新挂', async () => {
    const { device: account, accountId } = await signedIn();
    const social = new TestDevice(server);
    expect((await bind(account, social)).status).toBe(200);
    const friend = await registered();
    await pair(friend, social);
    expect((await social.call('DELETE', '/v1/devices')).status).toBe(204);
    expect(await boundDevice(accountId)).toBeUndefined();
    expect(await friendsOf(friend)).toEqual([]);
    const again = new TestDevice(server);
    expect((await bind(account, again)).body).toEqual({ deviceId: again.deviceId, moved: false });
    await pair(friend, again);

    expect((await account.call('DELETE', '/v1/account')).status).toBe(204);
    expect(await boundDevice(accountId)).toBeUndefined();
    expect(await friendsOf(friend)).toEqual([]);
    expect((await again.call('GET', '/v1/friends')).status).toBe(401);
  });

  it('多余字段与不合法参数被拒', async () => {
    const { device: account } = await signedIn();
    const social = new TestDevice(server);
    expect((await account.call('POST', '/v1/account/social', { ...socialBindBody(social, account.deviceId), extra: 1 })).body.code).toBe('INVALID_REQUEST');
    expect((await account.call('POST', '/v1/account/social', { ...socialBindBody(social, account.deviceId), takeover: 'yes' })).body.code).toBe('INVALID_REQUEST');
    expect((await social.call('POST', '/v1/friends/moves/ack', { deviceIds: [] })).status).toBe(401);
    const friend = await registered();
    expect((await friend.call('POST', '/v1/friends/moves/ack', { deviceIds: ['short'] })).body.code).toBe('INVALID_REQUEST');
    expect((await friend.call('GET', '/v1/friends?keys=2')).body.code).toBe('INVALID_REQUEST');
  });
});
