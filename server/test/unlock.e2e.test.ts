import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { randomBytes } from 'node:crypto';
import { mkdir, rm, utimes, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { unlockKeepDaysAfterPublic } from 'src/common/relay_limits';
import { UnlockService } from 'src/modules/unlock/unlock.service';
import { PointsService } from 'src/modules/points/points.service';
import { PointsRetentionTask } from 'src/modules/points/points_retention.task';
import { insertAccount } from './account_fixture';
import { TestDevice } from './test_device';

// 解锁（规则见 src/modules/unlock/unlock_rules.ts）：配置写进发布目录的 rollout.json，账号直接在库里登记（账号登录本身在 account.e2e.test.ts 测）。
let app: NestExpressApplication;
let server: string;
let database: DataSource;
let stamp = Date.now() / 1000;

const levels = [0, 500, 3000, 10000, 30000, 80000];
const rolloutFile = () => join(env().releasesDir, 'rollout.json');
const writeRollout = async (unlocks: Record<string, unknown>[]) => {
  await writeFile(rolloutFile(), JSON.stringify({ flags: [], levels, unlocks, envelope: null }));
  stamp += 10;
  await utimes(rolloutFile(), stamp, stamp);
};

const signedIn = async () => {
  const device = new TestDevice(server);
  expect((await device.register()).status).toBe(200);
  const accountId = randomBytes(16).toString('base64url');
  const now = new Date();
  await insertAccount(database, accountId, now);
  await database.query('INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, device.deviceId, now, now]);
  return { device, accountId };
};

const earn = (accountId: string, amount: number, days = 300) =>
  database.query('INSERT INTO points_grant (account_id, amount, remaining, source, source_key, expire_time, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', [
    accountId,
    amount,
    amount,
    'challenge',
    randomBytes(8).toString('hex'),
    new Date(Date.now() + days * 86400_000),
    new Date(),
    new Date(),
  ]);

const state = async (device: TestDevice) => {
  const response = await device.call('GET', '/v1/unlocks');
  expect(response.status, JSON.stringify(response.body)).toBe(200);
  return response.body as { level: number; open: string[] };
};
const buy = (device: TestDevice, id: string) => device.call('POST', `/v1/unlocks/${id}/buy`);
const rows = async (accountId: string) => (await database.query('SELECT unlock_id AS unlockId, source, price FROM account_unlock WHERE account_id = ? ORDER BY unlock_id', [accountId])) as { unlockId: string; source: string; price: number }[];

const past = new Date(Date.now() - 86400_000).toISOString();
const future = new Date(Date.now() + 30 * 86400_000).toISOString();

beforeAll(async () => {
  await mkdir(env().releasesDir, { recursive: true });
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  database = app.get(DataSource);
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
});

afterAll(async () => {
  await rm(rolloutFile(), { force: true });
  await app.close();
});

describe('解锁', () => {
  it('没登录应用账号回 ACCOUNT_NOT_FOUND', async () => {
    const device = new TestDevice(server);
    expect((await device.register()).status).toBe(200);
    expect((await device.call('GET', '/v1/unlocks')).body.code).toBe('ACCOUNT_NOT_FOUND');
    expect((await buy(device, 'game.demo')).body.code).toBe('ACCOUNT_NOT_FOUND');
  });

  it('谁能用：公开了人人能用，等级够直接开，只写价格的买了才开，下架的谁都不能用；配置读不了按没有解锁算', async () => {
    await writeRollout([
      { id: 'game.open', title: '已公开', publicAt: past },
      { id: 'game.early', title: '抢先玩', minLevel: 2, publicAt: future },
      { id: 'toolbox.paid', title: '付费', price: 100 },
      { id: 'toolbox.gone', title: '下架', minLevel: 1, retired: true },
    ]);
    const { device, accountId } = await signedIn();
    expect(await state(device)).toMatchObject({ level: 0, open: ['game.open'] });
    await earn(accountId, 3000);
    expect(await state(device)).toMatchObject({ level: 2, open: ['game.open', 'game.early'] });
    await writeFile(rolloutFile(), '{broken');
    stamp += 10;
    await utimes(rolloutFile(), stamp, stamp);
    const printed = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    expect(await state(device)).toMatchObject({ open: [] });
    expect(printed).toHaveBeenCalled();
    printed.mockRestore();
  });

  it('花积分买：不够不记也不扣；够了先扣快过期的、记一笔花费；再买不再扣；公开的、下架的、没写价格的、不存在的买不了；等级够的不扣', async () => {
    await writeRollout([
      { id: 'toolbox.paid', title: '付费工具', price: 100, minLevel: 3 },
      { id: 'game.open', title: '已公开', price: 50, publicAt: past },
      { id: 'game.level', title: '等级', minLevel: 1 },
      { id: 'toolbox.gone', title: '下架', price: 10, retired: true },
    ]);
    const { device, accountId } = await signedIn();
    const short = await buy(device, 'toolbox.paid');
    expect(short.status).toBe(409);
    expect(short.body).toMatchObject({ code: 'POINTS_SHORT', price: 100, balance: 0 });
    expect(await rows(accountId)).toEqual([]);

    await earn(accountId, 80, 200);
    await earn(accountId, 40, 10);
    const bought = await buy(device, 'toolbox.paid');
    expect(bought.status, JSON.stringify(bought.body)).toBe(200);
    expect(bought.body.open).toEqual(['toolbox.paid', 'game.open']);
    expect(await rows(accountId)).toEqual([{ unlockId: 'toolbox.paid', source: 'buy', price: 100 }]);
    const remaining = (await database.query('SELECT remaining FROM points_grant WHERE account_id = ? ORDER BY expire_time', [accountId])) as { remaining: number }[];
    expect(remaining.map((row) => row.remaining)).toEqual([0, 20]);
    const entries = (await device.call('GET', '/v1/points/entries')).body.entries as { kind: string; amount: number; note: string }[];
    expect(entries[0]).toMatchObject({ kind: 'spend', amount: -100, note: '解锁 · 付费工具' });
    expect((await device.call('GET', '/v1/points')).body).toMatchObject({ balance: 20, earned: 120 });

    expect((await buy(device, 'toolbox.paid')).status).toBe(200);
    expect((await device.call('GET', '/v1/points')).body.balance).toBe(20);
    for (const id of ['game.open', 'game.level', 'toolbox.gone', 'game.nothing']) expect((await buy(device, id)).body.code, id).toBe('UNLOCK_UNAVAILABLE');

    // 等级够的不扣：同一项另一个账号到 Lv3 再买，直接算开着。
    const rich = await signedIn();
    await earn(rich.accountId, 10000);
    expect((await buy(rich.device, 'toolbox.paid')).body.open).toContain('toolbox.paid');
    expect(await rows(rich.accountId)).toEqual([]);
    expect((await rich.device.call('GET', '/v1/points')).body.balance).toBe(10000);
  });

  it('抽签按等级加权：抽中的记一条，之后比例调低、降级也照旧能用；放量写 0 的没有这一说（解锁没有关停，要关就标下架）', async () => {
    await writeRollout([{ id: 'toolbox.lottery', title: '内测', percent: 100 }]);
    const { device, accountId } = await signedIn();
    expect((await state(device)).open).toEqual(['toolbox.lottery']);
    expect(await rows(accountId)).toEqual([{ unlockId: 'toolbox.lottery', source: 'drawn', price: 0 }]);
    await writeRollout([{ id: 'toolbox.lottery', title: '内测', percent: 1, minLevel: 5 }]);
    expect((await state(device)).open).toEqual(['toolbox.lottery']);
    await writeRollout([{ id: 'toolbox.lottery', title: '内测', percent: 1, retired: true }]);
    expect((await state(device)).open).toEqual([]);
  });

  it('清理：下架的买过的退回积分（不算等级）后删记录，抽中的直接删；公开满 30 天的删记录、不退；注销账号连带删', async () => {
    await writeRollout([
      { id: 'toolbox.paid', title: '付费工具', price: 100 },
      { id: 'toolbox.lottery', title: '内测', percent: 100 },
      { id: 'game.public', title: '新游戏', price: 30, publicAt: future },
    ]);
    const { device, accountId } = await signedIn();
    await earn(accountId, 500);
    await buy(device, 'toolbox.paid');
    await buy(device, 'game.public');
    expect((await rows(accountId)).map((row) => row.unlockId)).toEqual(['game.public', 'toolbox.lottery', 'toolbox.paid']);
    expect((await device.call('GET', '/v1/points')).body).toMatchObject({ balance: 370, earned: 500, level: 1 });

    const longAgo = new Date(Date.now() - (unlockKeepDaysAfterPublic + 1) * 86400_000).toISOString();
    await writeRollout([
      { id: 'toolbox.paid', title: '付费工具', price: 100, retired: true },
      { id: 'toolbox.lottery', title: '内测', percent: 100, retired: true },
      { id: 'game.public', title: '新游戏', price: 30, publicAt: longAgo },
    ]);
    await app.get(UnlockService).sweep();
    expect(await rows(accountId)).toEqual([]);
    const points = (await device.call('GET', '/v1/points')).body as { balance: number; earned: number; level: number };
    expect(points).toMatchObject({ balance: 470, earned: 500, level: 1 });
    const entries = (await device.call('GET', '/v1/points/entries')).body.entries as { kind: string; amount: number; note: string }[];
    expect(entries[0]).toMatchObject({ kind: 'refund', amount: 100, note: '退回 · 付费工具' });
    // 再跑一轮不会重复退。
    await app.get(UnlockService).sweep();
    expect((await device.call('GET', '/v1/points')).body.balance).toBe(470);

    await writeRollout([{ id: 'toolbox.paid2', title: '付费工具二', price: 10 }]);
    await buy(device, 'toolbox.paid2');
    expect(await rows(accountId)).toHaveLength(1);
    expect((await device.call('DELETE', '/v1/account')).status).toBe(204);
    expect(await rows(accountId)).toEqual([]);
  });

  it('配置不合规的不往外发：编号重复，没下架的一个条件也没写，下架只认 true', async () => {
    const printed = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    for (const unlocks of [
      [{ id: 'a', title: 'A', price: 1 }, { id: 'a', title: 'B', price: 2 }],
      [{ id: 'a', title: 'A' }],
      [{ id: 'a', title: 'A', price: 1, retired: false }],
      [{ id: 'a', title: 'A', publicAt: '2026-12-01T00:00:00' }],
      [{ id: 'a', title: '', price: 1 }],
      [{ id: 'a', title: 'A', minLevel: 6 }],
    ]) {
      await writeRollout(unlocks);
      const response = await new TestDevice(server).call('GET', '/v1/app/rollout');
      expect(response.status, JSON.stringify(unlocks)).toBe(500);
    }
    printed.mockRestore();
  });

  // 11-28 Codex 复核 F05：定时任务一次给一批账号写积分（下架退回、到期清零），原来先锁解锁记录或获得、再写积分，和注销「先锁账号行、再删积分与解锁」的先后相反：
  // 注销删完积分、还没删解锁时任务插进来，两边各等对方（InnoDB 判死锁回滚一边），或者给已注销的账号写进积分。现在任务先按账号号锁账号行。
  describe('定时任务与注销交错', () => {
    // 注销做完积分那一步、还没删别的时停住（此时拿着账号行的排他锁与积分表上这个账号的间隙锁）。
    const pauseDeletionAfterPoints = () => {
      let release!: () => void, reached!: () => void;
      const gate = new Promise<void>((resolve) => (release = resolve)), arrived = new Promise<void>((resolve) => (reached = resolve));
      const points = app.get(PointsService), original = points.deleteAccountsIn.bind(points);
      const spy = vi.spyOn(points, 'deleteAccountsIn').mockImplementation(async (...args) => {
        await original(...args);
        reached();
        await gate;
      });
      return { arrived, release: () => release(), restore: () => spy.mockRestore() };
    };
    const waiting = async (pattern: string) => {
      for (let attempt = 0; attempt < 300; attempt++) {
        if (((await database.query('SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE ?', [pattern])) as unknown[]).length > 0) return true;
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      return false;
    };

    it('下架退积分：等注销提交，已注销的不退、不死锁、不留积分；还在的账号照常退', async () => {
      await writeRollout([{ id: 'toolbox.synthetic_gone', title: '下架', price: 10, retired: true }]);
      const leaving = await signedIn(), staying = await signedIn();
      for (const { accountId } of [leaving, staying]) {
        await database.query('INSERT INTO account_unlock (account_id, unlock_id, source, price, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?)', [accountId, 'toolbox.synthetic_gone', 'buy', 10, new Date(), new Date()]);
      }
      const pause = pauseDeletionAfterPoints();
      try {
        const deleting = leaving.device.call('DELETE', '/v1/account').then((response) => response);
        await pause.arrived;
        const sweeping = app.get(UnlockService).sweep();
        expect(await waiting('SELECT account_id AS accountId FROM app_account WHERE account_id IN (%) ORDER BY account_id FOR SHARE'), '退积分先等账号行').toBe(true);
        pause.release();
        expect((await deleting).status).toBe(204);
        await sweeping;
      } finally {
        pause.release();
        pause.restore();
      }
      expect(await database.query('SELECT id FROM points_grant WHERE account_id = ?', [leaving.accountId])).toHaveLength(0);
      expect(await database.query('SELECT id FROM points_entry WHERE account_id = ?', [leaving.accountId])).toHaveLength(0);
      expect(await database.query('SELECT id FROM account_unlock WHERE unlock_id = ?', ['toolbox.synthetic_gone'])).toHaveLength(0);
      expect((await database.query('SELECT kind, amount FROM points_entry WHERE account_id = ?', [staying.accountId])) as unknown[]).toEqual([{ kind: 'refund', amount: 10 }]);
    });

    it('积分到期清零：等注销提交，已注销的不记过期流水、不死锁；还在的账号照常清零记流水', async () => {
      const leaving = await signedIn(), staying = await signedIn();
      for (const { accountId } of [leaving, staying]) await earn(accountId, 30, -1);
      const pause = pauseDeletionAfterPoints();
      try {
        const deleting = leaving.device.call('DELETE', '/v1/account').then((response) => response);
        await pause.arrived;
        const sweeping = app.get(PointsRetentionTask).sweep();
        expect(await waiting('SELECT account_id AS accountId FROM app_account WHERE account_id IN (%) ORDER BY account_id FOR SHARE'), '到期清零先等账号行').toBe(true);
        pause.release();
        expect((await deleting).status).toBe(204);
        await sweeping;
      } finally {
        pause.release();
        pause.restore();
      }
      expect(await database.query('SELECT id FROM points_entry WHERE account_id = ?', [leaving.accountId])).toHaveLength(0);
      expect(await database.query('SELECT id FROM points_grant WHERE account_id = ?', [leaving.accountId])).toHaveLength(0);
      expect((await database.query('SELECT kind, amount FROM points_entry WHERE account_id = ?', [staying.accountId])) as unknown[]).toEqual([{ kind: 'expire', amount: -30 }]);
      expect((await database.query('SELECT remaining FROM points_grant WHERE account_id = ?', [staying.accountId])) as unknown[]).toEqual([{ remaining: 0 }]);
    });

    it('门禁之前留下的孤儿行（账号已不在）：退积分与到期都不给它写积分，记录照样清掉，不会每轮被重新选中', async () => {
      await writeRollout([{ id: 'toolbox.synthetic_orphan', title: '下架', price: 10, retired: true }]);
      const ghost = randomBytes(16).toString('base64url');
      await database.query('INSERT INTO account_unlock (account_id, unlock_id, source, price, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?)', [ghost, 'toolbox.synthetic_orphan', 'buy', 10, new Date(), new Date()]);
      await earn(ghost, 30, -1);
      await app.get(UnlockService).sweep();
      await app.get(PointsRetentionTask).sweep();
      expect(await database.query('SELECT id FROM account_unlock WHERE account_id = ?', [ghost])).toHaveLength(0);
      expect(await database.query('SELECT id FROM points_entry WHERE account_id = ?', [ghost])).toHaveLength(0);
      expect((await database.query('SELECT remaining FROM points_grant WHERE account_id = ?', [ghost])) as unknown[]).toEqual([{ remaining: 0 }]);
    });
  });
});
