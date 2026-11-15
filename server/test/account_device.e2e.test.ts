import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { accountRecoveryPerDevicePerDay } from 'src/common/relay_limits';
import { AccountKeys } from 'src/modules/account/account_keys';
import { AccountRetentionTask } from 'src/modules/account/account_retention.task';
import { kingoSource } from 'src/modules/kingo/kingo_verifier';
import { TestDevice } from './test_device';

// 设备核对、扫码授权与找回（人工决策见 src/modules/account/account.service.ts 的 deviceSignIn）。中转不连学校，用不上假教务。
let app: NestExpressApplication;
let server: string;
let database: DataSource;
let sequence = 0;
const student = () => `2026${String(++sequence).padStart(6, '0')}${Date.now() % 1000}`;

const body = (device: TestDevice, loginId: string) => ({ signPublicKey: device.signPublicKey, boxPublicKey: device.boxPublicKey, loginId });
const deviceSignIn = (device: TestDevice, loginId: string) => device.call('POST', '/v1/account/device-sign-in', body(device, loginId));
const signedIn = async (loginId: string) => {
  const device = new TestDevice(server);
  const response = await deviceSignIn(device, loginId);
  expect(response.body.status).toBe('signedIn');
  return { device, accountId: response.body.account.accountId as string };
};

beforeAll(async () => {
  process.env.RELAY_KINGO_BASE = 'http://127.0.0.1:9';
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  database = app.get(DataSource);
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
});

afterAll(async () => {
  await app.close();
});

describe('设备核对', () => {
  it('学号没有账号就新建，和教务核对用同一个学号哈希；同一学号别的设备再来是 exists、不登记到账号', async () => {
    const loginId = student();
    const { device, accountId } = await signedIn(loginId);
    expect(accountId).toMatch(/^[A-Za-z0-9_-]{22}$/);
    expect((await device.call('GET', '/v1/account')).body).toMatchObject({ accountId, providers: ['kingo'], deviceCount: 1, recoveries: [] });
    const [row] = (await database.query('SELECT subject_hash AS subjectHash FROM account_identity WHERE account_id = ?', [accountId])) as { subjectHash: string }[];
    expect(row.subjectHash).toBe(app.get(AccountKeys).subjectHash('kingo', `${kingoSource}\n${loginId}`));
    expect(row.subjectHash).not.toContain(loginId);
    const other = new TestDevice(server);
    expect((await deviceSignIn(other, loginId)).body).toEqual({ status: 'exists', account: null });
    expect((await other.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
  });

  it('账号的设备都退出了，设备核对直接登回原来的账号', async () => {
    const loginId = student();
    const { device, accountId } = await signedIn(loginId);
    expect((await device.call('DELETE', '/v1/devices')).status).toBe(204);
    const again = new TestDevice(server);
    expect((await deviceSignIn(again, loginId)).body.account).toMatchObject({ accountId, created: false });
  });

  it('学号不合规的不认', async () => {
    const device = new TestDevice(server);
    expect((await deviceSignIn(device, '学号')).status).toBe(400);
  });
});

describe('扫码授权', () => {
  it('新设备出示二维码，同一学号已登录的设备批准后加进账号；新设备轮询拿到账号', async () => {
    const loginId = student();
    const { device: owner, accountId } = await signedIn(loginId);
    const fresh = new TestDevice(server);
    expect((await deviceSignIn(fresh, loginId)).body.status).toBe('exists');
    const join = await fresh.call('POST', '/v1/account/joins', body(fresh, loginId));
    expect(join.status).toBe(200);
    const { ticketId, code } = join.body as { ticketId: string; code: string };
    expect(code).toMatch(/^\d{6}$/);
    expect((await fresh.call('GET', `/v1/account/joins/${ticketId}`)).body).toEqual({ state: 'pending', account: null });
    expect((await owner.call('POST', `/v1/account/joins/${ticketId}/approve`, { code })).status).toBe(204);
    expect((await fresh.call('GET', `/v1/account/joins/${ticketId}`)).body).toMatchObject({ state: 'approved', account: { accountId, created: false } });
    expect((await fresh.call('GET', '/v1/account')).body).toMatchObject({ accountId, deviceCount: 2 });
  });

  it('核对码不对、别的学号的账号批准、别的设备来问、票据过期都不认', async () => {
    const loginId = student();
    const { device: owner } = await signedIn(loginId);
    const { device: stranger } = await signedIn(student());
    const fresh = new TestDevice(server);
    const { ticketId, code } = (await fresh.call('POST', '/v1/account/joins', body(fresh, loginId))).body as { ticketId: string; code: string };
    const wrong = code === '000000' ? '000001' : '000000';
    expect((await owner.call('POST', `/v1/account/joins/${ticketId}/approve`, { code: wrong })).body.code).toBe('JOIN_NOT_FOUND');
    expect((await stranger.call('POST', `/v1/account/joins/${ticketId}/approve`, { code })).body.code).toBe('JOIN_MISMATCH');
    expect((await stranger.call('GET', `/v1/account/joins/${ticketId}`)).body.code).toBe('JOIN_NOT_FOUND');
    expect((await fresh.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
    await app.get<Redis>(REDIS).del(RedisKeys.accountJoin(ticketId));
    expect((await owner.call('POST', `/v1/account/joins/${ticketId}/approve`, { code })).body.code).toBe('JOIN_NOT_FOUND');
  });
});

describe('找回', () => {
  const backdate = (recoveryId: string, days: number) => database.query('UPDATE account_recovery SET create_time = ? WHERE id = ?', [new Date(Date.now() - days * 86400_000), recoveryId]);

  it('还有设备登着时提交申请：账号的设备看得到、拒绝了就不生效；再申请 3 天后没人拒绝就生效', async () => {
    const loginId = student();
    const { device: owner, accountId } = await signedIn(loginId);
    const lost = new TestDevice(server);
    const first = await lost.call('POST', '/v1/account/recoveries', body(lost, loginId));
    expect(first.body).toMatchObject({ state: 'pending', account: null });
    expect(Math.abs((first.body.grantAt as number) - (Date.now() + 3 * 86400_000))).toBeLessThan(60_000);
    const listed = (await owner.call('GET', '/v1/account')).body.recoveries as { recoveryId: string }[];
    expect(listed.map((item) => item.recoveryId)).toEqual([first.body.recoveryId]);
    expect((await owner.call('POST', `/v1/account/recoveries/${first.body.recoveryId}/deny`)).status).toBe(204);
    expect((await lost.call('GET', '/v1/account/recoveries/mine')).body.state).toBe('denied');
    expect((await owner.call('POST', `/v1/account/recoveries/${first.body.recoveryId}/approve`)).body.code).toBe('JOIN_NOT_FOUND');

    const second = await lost.call('POST', '/v1/account/recoveries', body(lost, loginId));
    expect((await lost.call('GET', '/v1/account/recoveries/mine')).body.state).toBe('pending');
    await backdate(second.body.recoveryId as string, 3.1);
    expect((await lost.call('GET', '/v1/account/recoveries/mine')).body).toMatchObject({ state: 'granted', account: { accountId } });
    expect((await lost.call('GET', '/v1/account')).body).toMatchObject({ accountId, deviceCount: 2, recoveries: [] });
  });

  it('账号的设备批准就马上生效；同一设备重复提交只留一条', async () => {
    const loginId = student();
    const { device: owner, accountId } = await signedIn(loginId);
    const lost = new TestDevice(server);
    const first = await lost.call('POST', '/v1/account/recoveries', body(lost, loginId));
    expect((await lost.call('POST', '/v1/account/recoveries', body(lost, loginId))).body.recoveryId).toBe(first.body.recoveryId);
    expect((await owner.call('POST', `/v1/account/recoveries/${first.body.recoveryId}/approve`)).status).toBe(204);
    expect((await lost.call('GET', '/v1/account/recoveries/mine')).body).toMatchObject({ state: 'granted', account: { accountId } });
  });

  it('同时有两台不同设备在申请：到期也都不生效（conflict）', async () => {
    const loginId = student();
    await signedIn(loginId);
    const one = new TestDevice(server), two = new TestDevice(server);
    const first = await one.call('POST', '/v1/account/recoveries', body(one, loginId));
    const second = await two.call('POST', '/v1/account/recoveries', body(two, loginId));
    await backdate(first.body.recoveryId as string, 4);
    await backdate(second.body.recoveryId as string, 4);
    expect((await one.call('GET', '/v1/account/recoveries/mine')).body.state).toBe('conflict');
    expect((await two.call('GET', '/v1/account/recoveries/mine')).body.state).toBe('conflict');
    expect((await one.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
  });

  it('学号还没有账号不能申请；每台设备每天有次数上限', async () => {
    const lost = new TestDevice(server);
    expect((await lost.call('POST', '/v1/account/recoveries', body(lost, student()))).body.code).toBe('ACCOUNT_NOT_FOUND');
    const loginId = student();
    await signedIn(loginId);
    for (let index = 1; index < accountRecoveryPerDevicePerDay; index++) await lost.call('POST', '/v1/account/recoveries', body(lost, loginId));
    expect((await lost.call('POST', '/v1/account/recoveries', body(lost, loginId))).body.code).toBe('RATE_LIMITED');
  });

  it('注销账号连带删找回申请；满 30 天的由清理任务删除', async () => {
    const loginId = student();
    const { device: owner, accountId } = await signedIn(loginId);
    const lost = new TestDevice(server);
    const old = await lost.call('POST', '/v1/account/recoveries', body(lost, loginId));
    await backdate(old.body.recoveryId as string, 31);
    await app.get(AccountRetentionTask).sweep();
    expect(await database.query('SELECT id FROM account_recovery WHERE id = ?', [old.body.recoveryId])).toHaveLength(0);
    const other = new TestDevice(server);
    await other.call('POST', '/v1/account/recoveries', body(other, loginId));
    expect((await owner.call('DELETE', '/v1/account')).status).toBe(204);
    expect(await database.query('SELECT id FROM account_recovery WHERE account_id = ?', [accountId])).toHaveLength(0);
  });
});
