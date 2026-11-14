import { createHash, randomBytes } from 'node:crypto';
import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { createConnection, Connection } from 'mysql2/promise';
import request from 'supertest';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { rewardDrawPerDevicePerHour, rewardDrawPerHour, rewardKeepDays } from 'src/common/relay_limits';
import { RewardAdminError, runRewardAdmin } from 'src/modules/reward/reward_admin';
import { RewardRetentionTask } from 'src/modules/reward/reward_retention.task';
import { RewardDice } from 'src/modules/reward/reward.service';
import { rewardChance, rewardReleased, rewardWeight } from 'src/modules/reward/reward_odds';
import { TestDevice } from './test_device';

let app: NestExpressApplication;
let server: string;
let database: DataSource;
let admin: Connection;
let roll: ReturnType<typeof vi.spyOn>;

const hour = 3600_000;

// 活动编号每个用例各取一个：活动行在服务端缓存 60 秒，同一编号在用例之间改设置不会立即生效。
let serial = 0;
const campaignKey = () => `test-${Date.now().toString(36)}-${serial++}`;

const lines = async function* (text: string) {
  for (const line of text.split('\n')) yield line;
};

// 经维护命令建活动、导入奖品（同维护者在服务器上的用法）。
const setup = async (options: { from?: number; to?: number; mode?: 'uniform' | 'weighted'; chance?: number; maxWeight?: number; prizes?: number } = {}) => {
  const key = campaignKey();
  const now = Date.now();
  const args = ['create', key, '--from', new Date(now + (options.from ?? -hour / 2)).toISOString(), '--to', new Date(now + (options.to ?? hour / 2)).toISOString(), '--mode', options.mode ?? 'uniform', '--chance', String(options.chance ?? 0.2)];
  if (options.mode === 'weighted') args.push('--max-weight', String(options.maxWeight ?? 3));
  await runRewardAdmin(admin, args, lines(''));
  const prizes = options.prizes ?? 3;
  if (prizes > 0) await runRewardAdmin(admin, ['import', key], lines(Array.from({ length: prizes }, (_, index) => `口令\t口令${index}\t附言${index}`).join('\n')));
  return key;
};

// 抽签人：登录了应用账号的设备。注册设备后直接在库里登记账号与一条教务登录身份（账号登录本身在 account.e2e.test.ts 测）；
// 注册接口同一来源每小时 20 台新设备，每个用例前清空限流。subject 是登录身份的主体哈希，给了同一个就是同一个人。
const registered = async (subject = randomBytes(32).toString('base64url')) => {
  const device = new TestDevice(server);
  expect((await device.register()).status).toBe(200);
  const accountId = randomBytes(16).toString('base64url'), now = new Date();
  await database.query('INSERT INTO app_account (account_id, last_seen_time, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, now, now, now]);
  await database.query('INSERT INTO account_identity (account_id, provider, subject_hash, create_time, update_time) VALUES (?, ?, ?, ?, ?)', [accountId, 'kingo', subject, now, now]);
  await database.query('INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, device.deviceId, now, now]);
  return device;
};

const draw = (device: TestDevice, key: string, body: Record<string, unknown>) => device.call('POST', `/v1/rewards/${key}/draw`, body);

// 库里的抽签人：登录身份的 sha256（同 reward.service.ts）。
const participantHash = (subject: string) => createHash('sha256').update(`SXD1-reward\nkingo\n${subject}`).digest('hex');

beforeAll(async () => {
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  database = app.get(DataSource);
  const { host, port, username, password, database: name } = env().mysql;
  admin = await createConnection({ host, port, user: username, password, database: name, timezone: 'Z' });
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
  roll = vi.spyOn(app.get(RewardDice), 'roll');
});

afterEach(() => {
  vi.restoreAllMocks();
});

afterAll(async () => {
  await admin.end();
  await app.close();
});

describe('概率模型', () => {
  it('平权人人一样；加权从 1 线性到上限，20 天封顶；概率不超过 1', () => {
    expect(rewardWeight('uniform', 30, 3)).toBe(1);
    expect(rewardWeight('weighted', 0, 3)).toBe(1);
    expect(rewardWeight('weighted', 10, 3)).toBe(2);
    expect(rewardWeight('weighted', 20, 3)).toBe(3);
    expect(rewardWeight('weighted', 30, 3)).toBe(3);
    expect(rewardChance(0.2, 3)).toBeCloseTo(0.6);
    expect(rewardChance(0.5, 3)).toBe(1);
  });

  it('均匀放量：24 小时 24 份每小时累计多放 1 份，最后一小时放完；时长不足一小时也能放完', () => {
    const start = new Date('2027-02-06T00:00:00Z'), end = new Date('2027-02-07T00:00:00Z');
    expect(rewardReleased(24, start, end, new Date(start.getTime() + 10 * 60_000))).toBe(1);
    expect(rewardReleased(24, start, end, new Date(start.getTime() + 5.5 * hour))).toBe(6);
    expect(rewardReleased(24, start, end, new Date(end.getTime() - 1))).toBe(24);
    expect(rewardReleased(5, start, new Date(start.getTime() + 20 * 60_000), new Date(start.getTime() + 60_000))).toBe(5);
    expect(rewardReleased(10, start, end, new Date(start.getTime() + 30 * 60_000))).toBe(1);
  });

  // 按模型的概率抽很多次，抽中率落在期望附近（不经数据库，验概率本身没写反）。
  it('抽中率与模型一致：平权 0.2；加权新用户 0.2、最活跃 0.6', () => {
    const dice = new RewardDice();
    const rate = (chance: number) => Array.from({ length: 20000 }, () => dice.roll() < chance).filter(Boolean).length / 20000;
    expect(rate(rewardChance(0.2, rewardWeight('uniform', 25, 3)))).toBeCloseTo(0.2, 1);
    expect(rate(rewardChance(0.2, rewardWeight('weighted', 0, 3)))).toBeCloseTo(0.2, 1);
    expect(rate(rewardChance(0.2, rewardWeight('weighted', 25, 3)))).toBeCloseTo(0.6, 1);
  });
});

describe('抽奖', () => {
  it('要求登录了应用账号的设备签名：不签名、没登记、签名不对回 UNAUTHORIZED，没登录应用账号回 ACCOUNT_NOT_FOUND，都不掷骰子', async () => {
    const key = await setup();
    const unsigned = await request(server).post(`/v1/rewards/${key}/draw`).send({ activeDays: 3 });
    expect(unsigned.status).toBe(401);
    expect(unsigned.body.code).toBe('UNAUTHORIZED');
    // 旧客户端的免签名请求同样不收。
    expect((await request(server).post(`/v1/rewards/${key}/draw`).send({ participant: 'AAAAAAAAAAAAAAAAAAAAAA', activeDays: 3 })).status).toBe(401);
    const stranger = new TestDevice(server);
    const unknown = await draw(stranger, key, { activeDays: 3 });
    expect(unknown.status).toBe(401);
    expect(unknown.body.code).toBe('UNAUTHORIZED');
    const device = await registered(), other = await registered();
    const path = `/v1/rewards/${key}/draw`, body = Buffer.from(JSON.stringify({ activeDays: 3 }));
    const forged = await request(server).post(path).set({ ...other.headers('POST', path, body), 'x-sxd-device': device.deviceId }).send(body.toString());
    expect(forged.status).toBe(401);
    const bare = new TestDevice(server);
    expect((await bare.register()).status).toBe(200);
    const anonymous = await draw(bare, key, { activeDays: 3 });
    expect(anonymous.status).toBe(404);
    expect(anonymous.body.code).toBe('ACCOUNT_NOT_FOUND');
    expect(roll).not.toHaveBeenCalled();
  });

  it('一个人一次活动只抽一次：换一台设备、注销后用同一身份重建账号，都还是第一次的结果；换个人才重新掷', async () => {
    const key = await setup();
    const subject = randomBytes(32).toString('base64url');
    roll.mockReturnValue(0.99);
    expect((await draw(await registered(subject), key, { activeDays: 3 })).body.result).toBe('missed');
    await database.query('DELETE d, a, i FROM account_identity i JOIN app_account a ON a.account_id = i.account_id JOIN account_device d ON d.account_id = i.account_id WHERE i.subject_hash = ?', [subject]);
    roll.mockReturnValue(0);
    expect((await draw(await registered(subject), key, { activeDays: 3 })).body.result).toBe('missed');
    expect((await draw(await registered(), key, { activeDays: 3 })).body.result).toBe('won');
    expect(roll).toHaveBeenCalledTimes(2);
  });

  it('活动不存在、还没开始或已经结束都回 closed，不记抽签', async () => {
    const device = await registered();
    expect((await draw(device, 'no-such-campaign', { activeDays: 3 })).body).toEqual({ result: 'closed', prize: null });
    const later = await setup({ from: hour, to: 2 * hour });
    expect((await draw(device, later, { activeDays: 3 })).body.result).toBe('closed');
    const ended = await setup({ from: -2 * hour, to: -hour });
    expect((await draw(device, ended, { activeDays: 3 })).body.result).toBe('closed');
    expect(roll).not.toHaveBeenCalled();
  });

  it('抽中给出奖品；同一个人再来返回同一个奖品，没抽中的再来也还是没抽中（不能重抽）；库里只存登录身份的哈希', async () => {
    const key = await setup();
    const luckySubject = randomBytes(32).toString('base64url'), unluckySubject = randomBytes(32).toString('base64url');
    const lucky = await registered(luckySubject), unlucky = await registered(unluckySubject);
    roll.mockReturnValue(0);
    const won = await draw(lucky, key, { activeDays: 5 });
    expect(won.status).toBe(200);
    expect(won.body).toEqual({ result: 'won', prize: { kind: 'password', content: '口令0', note: '附言0' } });
    roll.mockReturnValue(0.99);
    expect((await draw(lucky, key, { activeDays: 30 })).body).toEqual(won.body);
    expect((await draw(unlucky, key, { activeDays: 5 })).body).toEqual({ result: 'missed', prize: null });
    roll.mockReturnValue(0);
    expect((await draw(unlucky, key, { activeDays: 5 })).body.result).toBe('missed');
    const hashes = (await database.query('SELECT participant_hash AS hash FROM reward_draw d JOIN reward_campaign c ON c.id = d.campaign_id WHERE c.campaign_key = ?', [key])) as { hash: string }[];
    expect(hashes.map((row) => row.hash).sort()).toEqual([luckySubject, unluckySubject].map(participantHash).sort());
  });

  it('按活跃度加权：同一个骰子点数，活跃的抽中、新用户没抽中；平权时活跃天数不起作用', async () => {
    roll.mockReturnValue(0.5);
    const weighted = await setup({ mode: 'weighted', chance: 0.2, maxWeight: 3 });
    expect((await draw(await registered(), weighted, { activeDays: 20 })).body.result).toBe('won');
    expect((await draw(await registered(), weighted, { activeDays: 0 })).body.result).toBe('missed');
    const uniform = await setup({ mode: 'uniform', chance: 0.2 });
    expect((await draw(await registered(), uniform, { activeDays: 30 })).body.result).toBe('missed');
  });

  it('均匀放量：24 小时的活动第一个小时只放 1 份，第二个抽中的人算没抽中', async () => {
    roll.mockReturnValue(0);
    const key = await setup({ from: -hour / 2, to: 23.5 * hour, prizes: 24 });
    expect((await draw(await registered(), key, { activeDays: 1 })).body.result).toBe('won');
    expect((await draw(await registered(), key, { activeDays: 1 })).body.result).toBe('missed');
  });

  it('并发：12 个人同时抽中、只有 5 份奖品，正好发出 5 份且各不相同；同一个人并发 5 次只记一次', async () => {
    roll.mockReturnValue(0);
    const key = await setup({ prizes: 5 });
    const devices = await Promise.all(Array.from({ length: 12 }, () => registered()));
    const results = await Promise.all(devices.map((device) => draw(device, key, { activeDays: 1 })));
    const prizes = results.filter((response) => response.body.result === 'won').map((response) => response.body.prize.content);
    expect(prizes).toHaveLength(5);
    expect(new Set(prizes).size).toBe(5);
    const again = await setup({ prizes: 5 });
    const same = await registered();
    const repeated = await Promise.all(Array.from({ length: 5 }, () => draw(same, again, { activeDays: 1 })));
    expect(new Set(repeated.map((response) => JSON.stringify(response.body))).size).toBe(1);
    const [counted] = (await database.query('SELECT COUNT(*) AS draws FROM reward_draw d JOIN reward_campaign c ON c.id = d.campaign_id WHERE c.campaign_key = ?', [again])) as { draws: string }[];
    expect(Number(counted.draws)).toBe(1);
  });

  it('参数不合法回 INVALID_REQUEST；请求体只认 activeDays，带上旧的参与号也不收', async () => {
    const key = await setup();
    const device = await registered();
    for (const body of [{ activeDays: 31 }, { activeDays: -1 }, {}, { activeDays: 1, extra: 1 }, { participant: 'AAAAAAAAAAAAAAAAAAAAAA', activeDays: 1 }]) {
      const response = await draw(device, key, body);
      expect(response.status).toBe(400);
      expect(response.body.code).toBe('INVALID_REQUEST');
    }
    expect((await draw(device, 'Bad_Key', { activeDays: 1 })).status).toBe(400);
  });

  // 把这一小时的计数直接拨到上限（同一个固定窗口），下一次就超了。
  const exhaust = async (scope: string, limit: number) => {
    const redis = app.get<Redis>(REDIS);
    const prefix = redis.options.keyPrefix ?? '';
    const [, keys] = await redis.scan('0', 'MATCH', `${prefix}${RedisKeys.rate(scope, '*', 0).replace(/:0$/, '')}:*`, 'COUNT', 1000);
    expect(keys).toHaveLength(1);
    await redis.set(keys[0].slice(prefix.length), limit, 'KEEPTTL');
  };

  it('同一台设备每小时超过上限回 RATE_LIMITED，同一出口的别的设备不受影响', async () => {
    vi.spyOn(Date, 'now').mockReturnValue((Math.floor(Date.now() / hour) + 0.5) * hour);
    const key = await setup();
    const device = await registered(), neighbor = await registered();
    await draw(device, key, { activeDays: 1 });
    await exhaust('reward_device', rewardDrawPerDevicePerHour);
    const response = await draw(device, key, { activeDays: 1 });
    expect(response.status).toBe(429);
    expect(response.body.code).toBe('RATE_LIMITED');
    expect((await draw(neighbor, key, { activeDays: 1 })).status).toBe(200);
  });

  it('同一 IP 每小时超过上限回 RATE_LIMITED', async () => {
    vi.spyOn(Date, 'now').mockReturnValue((Math.floor(Date.now() / hour) + 0.5) * hour);
    const key = await setup();
    const device = await registered();
    await draw(device, key, { activeDays: 1 });
    await exhaust('reward_draw', rewardDrawPerHour);
    const response = await draw(await registered(), key, { activeDays: 1 });
    expect(response.status).toBe(429);
    expect(response.body.code).toBe('RATE_LIMITED');
  });

  it('设备删除自己（DELETE /v1/devices）后不能再抽；抽签记录照旧留到活动保留期', async () => {
    roll.mockReturnValue(0.99);
    const key = await setup();
    const subject = randomBytes(32).toString('base64url');
    const device = await registered(subject);
    expect((await draw(device, key, { activeDays: 2 })).body.result).toBe('missed');
    expect((await device.call('DELETE', '/v1/devices')).status).toBe(204);
    const after = await draw(device, key, { activeDays: 2 });
    expect(after.status).toBe(401);
    const [counted] = (await database.query('SELECT COUNT(*) AS draws FROM reward_draw WHERE participant_hash = ?', [participantHash(subject)])) as { draws: string }[];
    expect(Number(counted.draws)).toBe(1);
  });
});

describe('维护命令与保留', () => {
  it('输入不对时说清楚是哪里；status 汇总奖品与抽签', async () => {
    await expect(runRewardAdmin(admin, ['create', 'x', '--from', '2027-02-06T00:00', '--to', '2027-02-07T00:00+08:00', '--mode', 'uniform', '--chance', '0.2'], lines(''))).rejects.toThrow(RewardAdminError);
    await expect(runRewardAdmin(admin, ['create', 'x', '--from', '2027-02-06T00:00+08:00', '--to', '2027-02-07T00:00+08:00', '--mode', 'lucky', '--chance', '0.2'], lines(''))).rejects.toThrow('--mode');
    await expect(runRewardAdmin(admin, ['import', 'no-such'], lines('口令\ta'))).rejects.toThrow('先 create');
    const key = await setup({ prizes: 0 });
    await expect(runRewardAdmin(admin, ['import', key], lines('口令\ta\n红包\tb'))).rejects.toThrow('第 2 行');
    expect(await runRewardAdmin(admin, ['import', key], lines('﻿口令\ta\n\n二维码\thttps://qr.alipay.com/demo\t扫码领'))).toContain('prizes=2');
    roll.mockReturnValue(0);
    await draw(await registered(), key, { activeDays: 4 });
    const status = await runRewardAdmin(admin, ['status', key], lines(''));
    expect(status).toContain('奖品 2 份，已发 1 份');
    expect(status).toContain('抽签 1 人，中 1 人');
  });

  it('活动结束 30 天后连同奖品与抽签记录删除，没到期的不动', async () => {
    roll.mockReturnValue(0);
    const device = await registered();
    const old = await setup();
    await draw(device, old, { activeDays: 1 });
    const recent = await setup();
    await draw(device, recent, { activeDays: 1 });
    const ended = new Date(Date.now() - (rewardKeepDays + 1) * 86400_000);
    await database.query('UPDATE reward_campaign SET starts_at = ?, ends_at = ? WHERE campaign_key = ?', [new Date(ended.getTime() - hour), ended, old]);
    await app.get(RewardRetentionTask).sweep();
    const count = async (key: string) => {
      const [row] = (await database.query(
        'SELECT (SELECT COUNT(*) FROM reward_campaign WHERE campaign_key = ?) AS campaigns, (SELECT COUNT(*) FROM reward_prize p JOIN reward_campaign c ON c.id = p.campaign_id WHERE c.campaign_key = ?) AS prizes',
        [key, key],
      )) as { campaigns: string; prizes: string }[];
      return [Number(row.campaigns), Number(row.prizes)];
    };
    expect(await count(old)).toEqual([0, 0]);
    expect(await count(recent)).toEqual([1, 3]);
    const [orphans] = (await database.query('SELECT COUNT(*) AS draws FROM reward_draw WHERE campaign_id NOT IN (SELECT id FROM reward_campaign)')) as { draws: string }[];
    expect(Number(orphans.draws)).toBe(0);
  });
});
