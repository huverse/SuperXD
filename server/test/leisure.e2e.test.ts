import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { randomBytes } from 'node:crypto';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { REDIS } from 'src/common/redis/redis.module';
import { leisureDeletePerDevicePerHour } from 'src/common/relay_limits';
import { insertAccount } from './account_fixture';
import { TestDevice } from './test_device';

// 娱乐与积分的「删除数据」（人工决策见客户端 lib/domain/leisure.dart）：账号直接在库里登记（账号登录本身在 account.e2e.test.ts 测）。
let app: NestExpressApplication;
let server: string;
let database: DataSource;

const signedIn = async () => {
  const device = new TestDevice(server);
  expect((await device.register()).status).toBe(200);
  const accountId = randomBytes(16).toString('base64url');
  const now = new Date();
  await insertAccount(database, accountId, now);
  await database.query('INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, device.deviceId, now, now]);
  return { device, accountId };
};

// 给账号放一笔积分、一条流水、一个挑战最好成绩与一项解锁。
const seed = async (accountId: string) => {
  const now = new Date(), later = new Date(Date.now() + 300 * 86400_000);
  await database.query('INSERT INTO points_grant (account_id, amount, remaining, source, source_key, expire_time, create_time, update_time) VALUES (?, 500, 500, ?, ?, ?, ?, ?)', [accountId, 'challenge', randomBytes(8).toString('hex'), later, now, now]);
  await database.query("INSERT INTO points_entry (account_id, kind, amount, note, ref, create_time, update_time) VALUES (?, 'earn', 500, '挑战', 'run', ?, ?)", [accountId, now, now]);
  await database.query('INSERT INTO challenge_best (account_id, challenge_id, points, run_id, ends_at, create_time, update_time) VALUES (?, ?, 500, ?, ?, ?, ?)', [accountId, 'weekly', randomBytes(8).toString('hex'), later, now, now]);
  await database.query("INSERT INTO account_unlock (account_id, unlock_id, source, price, create_time, update_time) VALUES (?, 'game.sudoku', 'buy', 100, ?, ?)", [accountId, now, now]);
};

const counts = async (accountId: string) => {
  const result: Record<string, number> = {};
  for (const table of ['points_grant', 'points_entry', 'challenge_best', 'account_unlock', 'app_account', 'account_device']) {
    const [{ count }] = (await database.query(`SELECT COUNT(*) AS count FROM ${table} WHERE account_id = ?`, [accountId])) as { count: string }[];
    result[table] = Number(count);
  }
  return result;
};

beforeAll(async () => {
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

describe('娱乐与积分的删除数据', () => {
  it('只删这个账号的积分、流水、挑战成绩与解锁；账号与设备照旧，别的账号不受影响', async () => {
    const mine = await signedIn(), other = await signedIn();
    await seed(mine.accountId);
    await seed(other.accountId);
    expect((await mine.device.call('DELETE', '/v1/leisure')).status).toBe(204);
    expect(await counts(mine.accountId)).toEqual({ points_grant: 0, points_entry: 0, challenge_best: 0, account_unlock: 0, app_account: 1, account_device: 1 });
    expect(await counts(other.accountId)).toEqual({ points_grant: 1, points_entry: 1, challenge_best: 1, account_unlock: 1, app_account: 1, account_device: 1 });
    expect((await mine.device.call('GET', '/v1/points')).body).toMatchObject({ balance: 0, level: 0 });
    expect((await mine.device.call('DELETE', '/v1/leisure')).status, '没有数据也照样回成功').toBe(204);
  });

  it('不签名回 UNAUTHORIZED，没登录应用账号回 ACCOUNT_NOT_FOUND', async () => {
    const response = await fetch(`${server}/v1/leisure`, { method: 'DELETE' });
    expect(response.status).toBe(401);
    const device = new TestDevice(server);
    expect((await device.register()).status).toBe(200);
    const missing = await device.call('DELETE', '/v1/leisure');
    expect(missing.status).toBe(404);
    expect(missing.body.code).toBe('ACCOUNT_NOT_FOUND');
  });

  it('同一台设备每小时超过上限回 RATE_LIMITED', async () => {
    const { device } = await signedIn();
    for (let index = 0; index < leisureDeletePerDevicePerHour; index++) expect((await device.call('DELETE', '/v1/leisure')).status).toBe(204);
    const limited = await device.call('DELETE', '/v1/leisure');
    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
  });
});
