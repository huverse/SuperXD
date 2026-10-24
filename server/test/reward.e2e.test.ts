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
import { rewardDrawPerHour, rewardKeepDays } from 'src/common/relay_limits';
import { RewardAdminError, runRewardAdmin } from 'src/modules/reward/reward_admin';
import { RewardRetentionTask } from 'src/modules/reward/reward_retention.task';
import { RewardDice } from 'src/modules/reward/reward.service';
import { rewardChance, rewardReleased, rewardWeight } from 'src/modules/reward/reward_odds';

let app: NestExpressApplication;
let server: string;
let database: DataSource;
let admin: Connection;
let roll: ReturnType<typeof vi.spyOn>;

const participant = () => randomBytes(16).toString('base64url');
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

const draw = (key: string, body: Record<string, unknown>) => request(server).post(`/v1/rewards/${key}/draw`).send(body);

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
  it('活动不存在、还没开始或已经结束都回 closed，不记抽签', async () => {
    expect((await draw('no-such-campaign', { participant: participant(), activeDays: 3 })).body).toEqual({ result: 'closed', prize: null });
    const later = await setup({ from: hour, to: 2 * hour });
    expect((await draw(later, { participant: participant(), activeDays: 3 })).body.result).toBe('closed');
    const ended = await setup({ from: -2 * hour, to: -hour });
    expect((await draw(ended, { participant: participant(), activeDays: 3 })).body.result).toBe('closed');
    expect(roll).not.toHaveBeenCalled();
  });

  it('抽中给出奖品；同一参与号再来返回同一个奖品，没抽中的再来也还是没抽中（不能重抽）；库里只存参与号的哈希', async () => {
    const key = await setup();
    const lucky = participant(), unlucky = participant();
    roll.mockReturnValue(0);
    const won = await draw(key, { participant: lucky, activeDays: 5 });
    expect(won.status).toBe(200);
    expect(won.body).toEqual({ result: 'won', prize: { kind: 'password', content: '口令0', note: '附言0' } });
    roll.mockReturnValue(0.99);
    expect((await draw(key, { participant: lucky, activeDays: 30 })).body).toEqual(won.body);
    expect((await draw(key, { participant: unlucky, activeDays: 5 })).body).toEqual({ result: 'missed', prize: null });
    roll.mockReturnValue(0);
    expect((await draw(key, { participant: unlucky, activeDays: 5 })).body.result).toBe('missed');
    const hashes = (await database.query('SELECT participant_hash AS hash FROM reward_draw d JOIN reward_campaign c ON c.id = d.campaign_id WHERE c.campaign_key = ?', [key])) as { hash: string }[];
    expect(hashes.map((row) => row.hash).sort()).toEqual([lucky, unlucky].map((value) => createHash('sha256').update(value).digest('hex')).sort());
  });

  it('按活跃度加权：同一个骰子点数，活跃的抽中、新用户没抽中；平权时活跃天数不起作用', async () => {
    roll.mockReturnValue(0.5);
    const weighted = await setup({ mode: 'weighted', chance: 0.2, maxWeight: 3 });
    expect((await draw(weighted, { participant: participant(), activeDays: 20 })).body.result).toBe('won');
    expect((await draw(weighted, { participant: participant(), activeDays: 0 })).body.result).toBe('missed');
    const uniform = await setup({ mode: 'uniform', chance: 0.2 });
    expect((await draw(uniform, { participant: participant(), activeDays: 30 })).body.result).toBe('missed');
  });

  it('均匀放量：24 小时的活动第一个小时只放 1 份，第二个抽中的人算没抽中', async () => {
    roll.mockReturnValue(0);
    const key = await setup({ from: -hour / 2, to: 23.5 * hour, prizes: 24 });
    expect((await draw(key, { participant: participant(), activeDays: 1 })).body.result).toBe('won');
    expect((await draw(key, { participant: participant(), activeDays: 1 })).body.result).toBe('missed');
  });

  it('并发：30 个人同时抽中、只有 5 份奖品，正好发出 5 份且各不相同；同一参与号并发 5 次只记一次', async () => {
    roll.mockReturnValue(0);
    const key = await setup({ prizes: 5 });
    const results = await Promise.all(Array.from({ length: 30 }, () => draw(key, { participant: participant(), activeDays: 1 })));
    const prizes = results.filter((response) => response.body.result === 'won').map((response) => response.body.prize.content);
    expect(prizes).toHaveLength(5);
    expect(new Set(prizes).size).toBe(5);
    const again = await setup({ prizes: 5 });
    const same = participant();
    const repeated = await Promise.all(Array.from({ length: 5 }, () => draw(again, { participant: same, activeDays: 1 })));
    expect(new Set(repeated.map((response) => JSON.stringify(response.body))).size).toBe(1);
    const [counted] = (await database.query('SELECT COUNT(*) AS draws FROM reward_draw d JOIN reward_campaign c ON c.id = d.campaign_id WHERE c.campaign_key = ?', [again])) as { draws: string }[];
    expect(Number(counted.draws)).toBe(1);
  });

  it('参数不合法回 INVALID_REQUEST', async () => {
    const key = await setup();
    for (const body of [{ participant: 'short', activeDays: 1 }, { participant: participant(), activeDays: 31 }, { participant: participant(), activeDays: -1 }, { participant: participant() }, { participant: participant(), activeDays: 1, extra: 1 }]) {
      const response = await draw(key, body);
      expect(response.status).toBe(400);
      expect(response.body.code).toBe('INVALID_REQUEST');
    }
    expect((await draw('Bad_Key', { participant: participant(), activeDays: 1 })).status).toBe(400);
  });

  it('同一 IP 每小时超过上限回 RATE_LIMITED', async () => {
    vi.spyOn(Date, 'now').mockReturnValue((Math.floor(Date.now() / hour) + 0.5) * hour);
    const key = await setup();
    await draw(key, { participant: participant(), activeDays: 1 });
    const redis = app.get<Redis>(REDIS);
    const prefix = redis.options.keyPrefix ?? '';
    const [, keys] = await redis.scan('0', 'MATCH', `${prefix}${RedisKeys.rate('reward_draw', '*', 0).replace(/:0$/, '')}:*`, 'COUNT', 1000);
    await redis.set(keys[0].slice(prefix.length), rewardDrawPerHour, 'KEEPTTL');
    const response = await draw(key, { participant: participant(), activeDays: 1 });
    expect(response.status).toBe(429);
    expect(response.body.code).toBe('RATE_LIMITED');
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
    await draw(key, { participant: participant(), activeDays: 4 });
    const status = await runRewardAdmin(admin, ['status', key], lines(''));
    expect(status).toContain('奖品 2 份，已发 1 份');
    expect(status).toContain('抽签 1 人，中 1 人');
  });

  it('活动结束 30 天后连同奖品与抽签记录删除，没到期的不动', async () => {
    roll.mockReturnValue(0);
    const old = await setup();
    await draw(old, { participant: participant(), activeDays: 1 });
    const recent = await setup();
    await draw(recent, { participant: participant(), activeDays: 1 });
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
