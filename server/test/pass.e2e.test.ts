import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import request from 'supertest';
import { randomBytes } from 'node:crypto';
import { mkdir, rm, utimes, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { passKeepDaysAfterExpire } from 'src/common/relay_limits';
import { PassService } from 'src/modules/pass/pass.service';
import { insertAccount } from './account_fixture';
import { TestDevice } from './test_device';

// 积分时长券（人工决策见 src/modules/pass/pass.service.ts）：清单写进发布目录的 passes.json，账号直接在库里登记（账号登录本身在 account.e2e.test.ts 测）。
let app: NestExpressApplication;
let server: string;
let database: DataSource;
let stamp = Date.now() / 1000;

const passesFile = () => join(env().releasesDir, 'passes.json');
const writePasses = async (body: unknown) => {
  await writeFile(passesFile(), typeof body === 'string' ? body : JSON.stringify(body));
  stamp += 10;
  await utimes(passesFile(), stamp, stamp);
};
const cinema = { id: 'toolbox.cinema', title: '电影院', price: 300, days: 7 };

const signedIn = async () => {
  const device = new TestDevice(server);
  expect((await device.register()).status).toBe(200);
  const accountId = randomBytes(16).toString('base64url');
  const now = new Date();
  await insertAccount(database, accountId, now);
  await database.query('INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, device.deviceId, now, now]);
  return { device, accountId };
};

const earn = (accountId: string, amount: number) =>
  database.query('INSERT INTO points_grant (account_id, amount, remaining, source, source_key, expire_time, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', [
    accountId,
    amount,
    amount,
    'challenge',
    randomBytes(8).toString('hex'),
    new Date(Date.now() + 300 * 86400_000),
    new Date(),
    new Date(),
  ]);
const balance = async (accountId: string) => Number(((await database.query('SELECT COALESCE(SUM(remaining), 0) AS total FROM points_grant WHERE account_id = ?', [accountId])) as { total: number | string }[])[0].total);

beforeAll(async () => {
  await mkdir(env().releasesDir, { recursive: true });
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  database = app.get(DataSource);
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
  await rm(passesFile(), { force: true });
});

afterAll(async () => {
  await rm(passesFile(), { force: true });
  await app.close();
});

describe('积分时长券', () => {
  it('没放 passes.json 时清单为空、谁都不收，买回 PASS_UNAVAILABLE、不扣积分', async () => {
    expect((await request(server).get('/v1/app/passes')).body).toEqual({ offers: [] });
    const { device, accountId } = await signedIn();
    await earn(accountId, 1000);
    const response = await device.call('POST', '/v1/passes/toolbox.cinema/buy');
    expect(response.status).toBe(409);
    expect(response.body.code).toBe('PASS_UNAVAILABLE');
    expect(await balance(accountId)).toBe(1000);
  });

  it('买一次扣一次积分、到期时刻按服务器算；续买往后叠加；积分不够回 POINTS_SHORT、不续', async () => {
    await writePasses({ offers: [cinema] });
    expect((await request(server).get('/v1/app/passes')).body).toEqual({ offers: [cinema] });
    const { device, accountId } = await signedIn();
    await earn(accountId, 700);
    expect((await device.call('GET', '/v1/passes')).body.held).toEqual([]);
    const first = await device.call('POST', '/v1/passes/toolbox.cinema/buy');
    expect(first.status, JSON.stringify(first.body)).toBe(200);
    const until = first.body.held[0].until as number;
    expect(Math.abs(until - (first.body.serverTime + 7 * 86400_000))).toBeLessThan(5000);
    const second = await device.call('POST', '/v1/passes/toolbox.cinema/buy');
    expect(second.body.held[0].until).toBe(until + 7 * 86400_000);
    expect(await balance(accountId)).toBe(100);
    const short = await device.call('POST', '/v1/passes/toolbox.cinema/buy');
    expect(short.status).toBe(409);
    expect(short.body.code).toBe('POINTS_SHORT');
    expect((await device.call('GET', '/v1/passes')).body.held[0].until).toBe(until + 7 * 86400_000);
    expect(await balance(accountId)).toBe(100);
  });

  it('到期的不算持有；到期满 30 天的由清理任务删掉；注销账号连带删', async () => {
    await writePasses({ offers: [cinema] });
    const { device, accountId } = await signedIn();
    const old = new Date(Date.now() - (passKeepDaysAfterExpire + 1) * 86400_000);
    await database.query('INSERT INTO account_pass (account_id, pass_id, expire_time, paid, create_time, update_time) VALUES (?, ?, ?, 300, ?, ?)', [accountId, 'toolbox.cinema', old, old, old]);
    expect((await device.call('GET', '/v1/passes')).body.held).toEqual([]);
    await app.get(PassService).sweep();
    expect(await database.query('SELECT id FROM account_pass WHERE account_id = ?', [accountId])).toHaveLength(0);
    await earn(accountId, 300);
    await device.call('POST', '/v1/passes/toolbox.cinema/buy');
    await database.transaction((manager) => app.get(PassService).deleteAccountsIn(manager, [accountId]));
    expect(await database.query('SELECT id FROM account_pass WHERE account_id = ?', [accountId])).toHaveLength(0);
  });

  it('passes.json 写坏（多出字段、天数越界、编号重复、不是 JSON）不往外发，回 INTERNAL', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
    for (const body of [
      { offers: [{ ...cinema, secret: 1 }] },
      { offers: [{ ...cinema, days: 0 }] },
      { offers: [cinema, cinema] },
      '{not json',
    ]) {
      await writePasses(body);
      const response = await request(server).get('/v1/app/passes');
      expect(response.status).toBe(500);
      expect(response.body.code).toBe('INTERNAL');
    }
    vi.restoreAllMocks();
  });

  it('没登录应用账号的设备看自己的券回 ACCOUNT_NOT_FOUND', async () => {
    const device = new TestDevice(server);
    expect((await device.register()).status).toBe(200);
    const response = await device.call('GET', '/v1/passes');
    expect(response.status).toBe(404);
  });
});
