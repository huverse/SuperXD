import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { randomBytes } from 'node:crypto';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { challengeRunKeepDays, pointsEntryKeepDays } from 'src/common/relay_limits';
import { ChallengeTasks } from 'src/modules/challenge/challenge.tasks';
import { ChallengeService } from 'src/modules/challenge/challenge.service';
import { PointsRetentionTask } from 'src/modules/points/points_retention.task';
import { TestDevice } from './test_device';

// 题库用双端判定向量里的题（向量带参考解，用例拿它交对的答案）：24 点的四张牌都能挖，八皇后挖锁定的行，数回挖有数字的格。
type Case = { tier: string; puzzle: unknown; answers: { answer: unknown; expect: { kind: string } }[] };
const vectors = JSON.parse(await readFile(new URL('./vectors/challenge_judge_v1.json', import.meta.url), 'utf8')) as { games: Record<string, Case[]> };
const reference = new Map<string, unknown>();
for (const cases of Object.values(vectors.games)) for (const item of cases) reference.set(JSON.stringify(item.puzzle), item.answers[0].answer);

const slotsOf = (game: string, puzzle: Record<string, unknown>) => {
  if (game === 'twentyfour') return (puzzle.numbers as number[]).map((value, at) => ({ at, value, key: value }));
  if (game === 'queens') return (puzzle.given as number[]).flatMap((value, at) => (value >= 0 ? [{ at, value, key: value + 1 }] : []));
  if (game === 'loop') return (puzzle.clues as number[]).flatMap((value, at) => (value >= 0 ? [{ at, value, key: value }] : []));
  return [];
};

const directory = join(env().releasesDir, 'challenge');
const games = ['hanoi', 'ice', 'twentyfour', 'queens', 'loop'];
const config = (overrides: Record<string, unknown> = {}) => ({
  version: 1,
  scoring: { levelBase: 10, timeFloor: 0.4, errorDecay: 0.9, passWeight: 0.5, depthBonus: 0.05, clearBonus: 0.25, timeBonus: 0.2, maxErrors: 2 },
  templates: {
    trio: {
      title: '三连环',
      label: '入门',
      timeLimit: 600,
      nodes: [
        { id: 'a', tier: 'entry', games: ['hanoi'] },
        { id: 'b', tier: 'entry', games: ['ice'] },
        { id: 'c', tier: 'entry', games: ['twentyfour'] },
      ],
      edges: [
        ['a', 'c'],
        ['b', 'c'],
      ],
    },
  },
  rotations: [{ id: 'weekly', every: 'week', templates: ['trio'] }],
  events: [],
  ...overrides,
});

let app: NestExpressApplication;
let server: string;
let database: DataSource;

const writeConfig = async (value: unknown) => {
  await writeFile(join(directory, 'config.json.tmp'), JSON.stringify(value));
  // 换文件即生效：先写临时文件再改名（同流水线上传），修改时间与大小都会变。
  await rm(join(directory, 'config.json'), { force: true });
  await writeFile(join(directory, 'config.json'), JSON.stringify(value));
};

// 一个登录了应用账号的设备：注册设备后直接在库里登记账号（账号登录本身在 account.e2e.test.ts 测）。
const signedIn = async () => {
  const device = new TestDevice(server);
  expect((await device.register()).status).toBe(200);
  const accountId = randomBytes(16).toString('base64url');
  const now = new Date();
  await database.query('INSERT INTO app_account (account_id, last_seen_time, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, now, now, now]);
  await database.query('INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, device.deviceId, now, now]);
  return { device, accountId };
};

type Level = { id: string; game: string; state: string; submissions: number; errors: number; key: number | null; teaser: string | null; puzzle: unknown; keyed: { from: string; at: number; key: number }[] };
type Run = { runId: string; challengeId: string; state: string; deadline: number; levels: Level[]; result: { points: number; awarded: number; ending: string } | null };

const list = (device: TestDevice, supported = games) => device.call('GET', `/v1/challenges?games=${supported.join(',')}`);
const start = async (device: TestDevice) => {
  const listed = await list(device);
  expect(listed.status).toBe(200);
  const response = await device.call('POST', `/v1/challenges/${listed.body.challenges[0].id as string}/runs`, { games });
  return response;
};
const level = (run: Run, id: string) => run.levels.find((item) => item.id === id)!;
const submit = (device: TestDevice, run: Run, id: string, answer: unknown, attempt = level(run, id).submissions) =>
  device.call('POST', `/v1/challenge-runs/${run.runId}/levels/${id}/answers`, { attempt, answer });
const solve = async (device: TestDevice, run: Run, id: string) => {
  const response = await submit(device, run, id, reference.get(JSON.stringify(level(run, id).puzzle)));
  expect(response.status, JSON.stringify(response.body)).toBe(200);
  expect(response.body.correct).toBe(true);
  return response.body as { correct: boolean; key: number | null; run: Run };
};

beforeAll(async () => {
  await mkdir(join(directory, 'bank'), { recursive: true });
  for (const game of games) {
    const entries = vectors.games[game]
      .filter((item) => item.tier === 'entry')
      .map((item, index) => ({ id: `${game}.entry.${index}`, puzzle: item.puzzle, difficulty: 2, slots: slotsOf(game, item.puzzle as Record<string, unknown>) }));
    await writeFile(join(directory, 'bank', `${game}.entry.json`), JSON.stringify({ version: 1, entries }));
  }
  await writeConfig(config());
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  database = app.get(DataSource);
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
});

afterAll(async () => {
  await rm(directory, { recursive: true, force: true });
  await app.close();
});

describe('积分与挑战', () => {
  it('没登录应用账号：挑战与积分都回 ACCOUNT_NOT_FOUND', async () => {
    const device = new TestDevice(server);
    await device.register();
    expect((await list(device)).body.code).toBe('ACCOUNT_NOT_FOUND');
    expect((await device.call('GET', '/v1/points')).body.code).toBe('ACCOUNT_NOT_FOUND');
  });

  it('列表：本周的挑战、限时与关数；客户端玩不了里面的游戏时标不能玩', async () => {
    const { device } = await signedIn();
    const listed = await list(device);
    expect(listed.body.activeRun).toBeNull();
    expect(listed.body.challenges).toEqual([expect.objectContaining({ title: '三连环', label: '入门', levels: 3, timeLimit: 600, best: null, playable: true })]);
    expect(listed.body.challenges[0].id).toMatch(/^weekly\.\d{4}-\d\d-\d\d\.trio$/);
    expect((await list(device, ['hanoi', 'ice'])).body.challenges[0].playable).toBe(false);
    expect((await device.call('POST', `/v1/challenges/${listed.body.challenges[0].id as string}/runs`, { games: ['hanoi', 'ice'] })).body.code).toBe('CHALLENGE_UNAVAILABLE');
    expect((await device.call('POST', '/v1/challenges/weekly.2020-01-06.trio/runs', { games })).body.code).toBe('CHALLENGE_NOT_FOUND');
  });

  it('整局走完：错交计数、重发只算一次、钥匙齐了才解锁、全过结算并记积分', async () => {
    const { device } = await signedIn();
    const started = await start(device);
    expect(started.status).toBe(200);
    let run = started.body as Run;
    expect(run.state).toBe('running');
    expect(level(run, 'a')).toMatchObject({ game: 'hanoi', state: 'open', key: null, teaser: null });
    expect(level(run, 'c')).toMatchObject({ game: 'twentyfour', state: 'locked', puzzle: null, keyed: [] });
    // 预告挖掉两张牌（a、b 各一把钥匙）。
    expect(level(run, 'c').teaser!.split('?').length - 1).toBe(2);
    expect((await submit(device, run, 'c', [])).body.code).toBe('LEVEL_LOCKED');

    const wrong = await submit(device, run, 'a', []);
    expect(wrong.body).toMatchObject({ correct: false, key: null });
    // 回复丢了重发同一个号：回原来的结果，不再计数。
    const replay = await submit(device, run, 'a', [], 0);
    expect(replay.body.correct).toBe(false);
    expect(level(replay.body.run as Run, 'a')).toMatchObject({ submissions: 1, errors: 1 });
    run = wrong.body.run as Run;

    const first = await solve(device, run, 'a');
    expect(first.key).not.toBeNull();
    expect(level(first.run, 'c').state).toBe('locked');
    const second = await solve(device, first.run, 'b');
    const consumer = level(second.run, 'c');
    expect(consumer.state).toBe('open');
    expect(consumer.keyed.map((slot) => slot.from).sort()).toEqual(['a', 'b']);
    expect(consumer.keyed.find((slot) => slot.from === 'a')!.key).toBe(first.key);
    expect(consumer.keyed.find((slot) => slot.from === 'b')!.key).toBe(second.key);
    expect(consumer.keyed.every((slot) => (consumer.puzzle as { numbers: number[] }).numbers[slot.at] === slot.key)).toBe(true);

    const last = await solve(device, second.run, 'c');
    expect(last.run.state).toBe('settled');
    expect(last.run.result).toMatchObject({ ending: 'cleared' });
    const { points, awarded } = last.run.result!;
    expect(points).toBeGreaterThan(0);
    expect(awarded).toBe(points);
    expect((await device.call('POST', `/v1/challenge-runs/${run.runId}/levels/c/answers`, { attempt: 1, answer: [] })).body.code).toBe('RUN_OVER');

    const summary = await device.call('GET', '/v1/points');
    expect(summary.body).toMatchObject({ balance: awarded, expiring: 0, expiringAt: null });
    const entries = await device.call('GET', '/v1/points/entries');
    expect(entries.body.entries).toEqual([expect.objectContaining({ kind: 'earn', amount: awarded, note: '入门·三连环' })]);
    expect(entries.body.next).toBeNull();
    expect((await list(device)).body.challenges[0].best).toBe(points);

    // 再来一局只过一关就结束：成绩没超过最好成绩，不加积分。
    const again = (await start(device)).body as Run;
    const partial = await solve(device, again, 'a');
    const ended = await device.call('POST', `/v1/challenge-runs/${again.runId}/end`);
    expect(ended.body.result).toMatchObject({ ending: 'ended', awarded: 0 });
    expect(ended.body.result.points).toBeLessThan(points);
    expect(partial.run.state).toBe('running');
    expect((await device.call('GET', '/v1/points')).body.balance).toBe(awarded);
  });

  it('一个账号同时只有一局；错交到上限算没过，剩下的开不了就结算', async () => {
    const { device } = await signedIn();
    const run = (await start(device)).body as Run;
    const blocked = await start(device);
    expect(blocked.status).toBe(409);
    expect(blocked.body).toMatchObject({ code: 'RUN_ACTIVE', runId: run.runId });
    expect((await list(device)).body.activeRun).toBe(run.runId);
    await submit(device, run, 'a', [], 0);
    const failed = await submit(device, run, 'a', [], 1);
    expect(level(failed.body.run as Run, 'a').state).toBe('failed');
    expect((failed.body.run as Run).state).toBe('running');
    const stuck = await solve(device, failed.body.run as Run, 'b');
    expect(stuck.run.result).toMatchObject({ ending: 'stuck' });
    expect((await start(device)).status).toBe(200);
  });

  it('服务器计时：到点的局看一眼就按到点结算，定时任务也会结算，过了的关照样记分', async () => {
    const { device } = await signedIn();
    const run = (await start(device)).body as Run;
    await solve(device, run, 'a');
    await database.query('UPDATE challenge_run SET deadline = ? WHERE run_id = ?', [new Date(Date.now() - 1000), run.runId]);
    const viewed = await device.call('GET', `/v1/challenge-runs/${run.runId}`);
    expect(viewed.body.state).toBe('settled');
    expect(viewed.body.result.ending).toBe('timeout');
    expect(viewed.body.result.points).toBeGreaterThan(0);
    expect((await submit(device, viewed.body as Run, 'b', [])).body.code).toBe('RUN_OVER');

    const other = (await signedIn()).device;
    const due = (await start(other)).body as Run;
    await database.query('UPDATE challenge_run SET deadline = ? WHERE run_id = ?', [new Date(Date.now() - 1000), due.runId]);
    expect(await app.get(ChallengeService).settleDue(Date.now())).toBeGreaterThanOrEqual(1);
    const [row] = (await database.query('SELECT active, ending FROM challenge_run WHERE run_id = ?', [due.runId])) as { active: number | null; ending: string }[];
    expect(row).toEqual({ active: null, ending: 'timeout' });
    // 别人的局看不到。
    expect((await device.call('GET', `/v1/challenge-runs/${due.runId}`)).body.code).toBe('RUN_NOT_FOUND');
  });

  it('注销应用账号连带删掉积分与挑战记录', async () => {
    const { device, accountId } = await signedIn();
    const run = (await start(device)).body as Run;
    for (const id of ['a', 'b', 'c']) await solve(device, (await device.call('GET', `/v1/challenge-runs/${run.runId}`)).body as Run, id);
    expect((await device.call('GET', '/v1/points')).body.balance).toBeGreaterThan(0);
    expect((await device.call('DELETE', '/v1/account')).status).toBe(204);
    for (const table of ['points_grant', 'points_entry', 'challenge_run', 'challenge_best']) {
      expect(await database.query(`SELECT id FROM ${table} WHERE account_id = ?`, [accountId]), table).toEqual([]);
    }
  });

  it('积分满 12 个月过期记一条过期流水；过期的流水与局按保留期删除', async () => {
    const { device, accountId } = await signedIn();
    const now = Date.now();
    const old = new Date(now - 2 * 86400_000);
    await database.query('INSERT INTO points_grant (account_id, amount, remaining, source, source_key, expire_time, create_time, update_time) VALUES (?, 50, 50, ?, ?, ?, ?, ?)', [accountId, 'challenge', `old-${accountId}`, old, old, old]);
    await database.query('INSERT INTO points_grant (account_id, amount, remaining, source, source_key, expire_time, create_time, update_time) VALUES (?, 30, 30, ?, ?, ?, ?, ?)', [accountId, 'challenge', `soon-${accountId}`, new Date(now + 3 * 86400_000), old, old]);
    expect((await device.call('GET', '/v1/points')).body).toMatchObject({ balance: 30, expiring: 30 });
    await app.get(PointsRetentionTask).sweep(new Date(now));
    const entries = (await device.call('GET', '/v1/points/entries')).body.entries as { kind: string; amount: number }[];
    expect(entries[0]).toMatchObject({ kind: 'expire', amount: -50 });
    const ancient = new Date(now - (pointsEntryKeepDays + 1) * 86400_000);
    await database.query('UPDATE points_entry SET create_time = ? WHERE account_id = ?', [ancient, accountId]);
    await app.get(PointsRetentionTask).sweep(new Date(now));
    expect(await database.query('SELECT id FROM points_entry WHERE account_id = ?', [accountId])).toEqual([]);

    const run = (await start(device)).body as Run;
    await device.call('POST', `/v1/challenge-runs/${run.runId}/end`);
    await database.query('UPDATE challenge_run SET end_time = ? WHERE run_id = ?', [new Date(now - (challengeRunKeepDays + 1) * 86400_000), run.runId]);
    await app.get(ChallengeTasks).sweep(now);
    expect(await database.query('SELECT id FROM challenge_run WHERE run_id = ?', [run.runId])).toEqual([]);
  });

  it('配置热加载：换文件即生效，写坏了接着用上一份', async () => {
    const { device } = await signedIn();
    const base = config() as { templates: { trio: Record<string, unknown> } };
    await writeConfig({ ...base, templates: { trio: { ...base.templates.trio, title: '改名三连环' } } });
    expect((await list(device)).body.challenges[0].title).toBe('改名三连环');
    await writeConfig({ ...base, templates: { trio: { ...base.templates.trio, edges: [['a', 'c'], ['c', 'a']] } } });
    expect((await list(device)).body.challenges[0].title).toBe('改名三连环');
    await writeConfig(config());
    expect((await list(device)).body.challenges[0].title).toBe('三连环');
  });
});
