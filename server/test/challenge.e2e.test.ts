import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { randomBytes } from 'node:crypto';
import { mkdir, readFile, rm, utimes, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { challengeRunKeepDays, pointsEntryKeepDays } from 'src/common/relay_limits';
import { ChallengeTasks } from 'src/modules/challenge/challenge.tasks';
import { ChallengeService } from 'src/modules/challenge/challenge.service';
import { PointsRetentionTask } from 'src/modules/points/points_retention.task';
import { insertAccount } from './account_fixture';
import { TestDevice } from './test_device';

// 题库用双端判定向量里的题（向量带参考解，用例拿它交对的答案）。碎片按题库写的：汉诺塔 3、冰面 6，所以门上的数是 9（相加）或 18（相乘），
// 入门档的 24 点按 9 取余加 1 都是 1，向量里的 24 点（1 6 9 9）有一张 1 能写成 ?。
type Case = { tier: string; puzzle: unknown; answers: { answer: unknown; expect: { kind: string } }[] };
const vectors = JSON.parse(await readFile(new URL('./vectors/challenge_judge_v1.json', import.meta.url), 'utf8')) as { games: Record<string, Case[]> };
// 冰面滑行与汉诺塔换了第 2 版写法：本文件的这两个游戏仍按第 1 版（旧文件名、只报游戏名），题从冻结的第 1 版向量里取。
const frozen = JSON.parse(await readFile(new URL('./vectors/challenge_judge_frozen.json', import.meta.url), 'utf8')) as { games: Record<string, Case[]> };
const legacy: Record<string, string> = { ice: 'ice@1', hanoi: 'hanoi@1' };
const casesOf = (game: string) => (game in legacy ? frozen.games[legacy[game]] : vectors.games[game]);
const reference = new Map<string, unknown>();
for (const cases of [...Object.values(vectors.games), ...Object.values(legacy).map((key) => frozen.games[key])]) for (const item of cases) reference.set(JSON.stringify(item.puzzle), item.answers[0].answer);

const fragments: Record<string, number> = { hanoi: 3, ice: 6, twentyfour: 25 };
// 向量里入门档的两道汉诺塔一模一样，加试题要另一道：再放一道挪到第 2 根柱子的（参考解按经典走法写好）。
const towerTwo = { disks: 3, start: [0, 0, 0], target: 1 };
reference.set(JSON.stringify(towerTwo), [1, 2, 5, 1, 6, 7, 1]);
const slotsOf = (game: string, puzzle: Record<string, unknown>) => (game === 'twentyfour' ? (puzzle.numbers as number[]).map((value, at) => ({ at, value })) : []);

const directory = join(env().releasesDir, 'challenge');
const games = ['hanoi', 'ice', 'twentyfour'];
const config = (overrides: Record<string, unknown> = {}, scoring: Record<string, unknown> = {}) => ({
  version: 1,
  scoring: { levelBase: 10, parSlack: 1.5, gatePenalty: 20, extraRatio: 0.15, extraFloor: 30, maxExtras: 0, timeFloor: 0.4, errorDecay: 0.9, passWeight: 0.5, depthBonus: 0.05, clearBonus: 0.25, timeBonus: 0.2, maxErrors: 2, ...scoring },
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
  await insertAccount(database, accountId, now);
  await database.query('INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, device.deviceId, now, now]);
  return { device, accountId };
};

type Level = { id: string; game: string; state: string; submissions: number; errors: number; letter: string | null; gate: { op: string; value: number | null } | null; consume: { kind: string; at: number; modulus: number; offset: number } | null; extraOf: string | null; puzzle: unknown };
type Run = { runId: string; challengeId: string; state: string; deadline: number; penaltySeconds: number; final: string; levels: Level[]; result: { points: number; awarded: number; ending: string } | null };
type Answered = { correct: boolean; fragment: number | null; extra: string | null; run: Run };

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
  return response.body as Answered;
};
const gate = (device: TestDevice, run: Run, id: string, value: number) => device.call('POST', `/v1/challenge-runs/${run.runId}/gates/${id}`, { value });
const final = (device: TestDevice, run: Run, value: number) => device.call('POST', `/v1/challenge-runs/${run.runId}/final`, { value });
// 门上的数：a、b 的碎片按门上写的相加或相乘。
const gateOf = (run: Run) => (level(run, 'c').gate!.op === 'product' ? fragments.hanoi * fragments.ice : fragments.hanoi + fragments.ice);
// 走完一整局：过 a、b，开门，过 c，输终章。
const clear = async (device: TestDevice, run: Run) => {
  let current = (await solve(device, run, 'a')).run;
  current = (await solve(device, current, 'b')).run;
  current = (await gate(device, current, 'c', gateOf(current))).body.run as Run;
  current = (await solve(device, current, 'c')).run;
  return (await final(device, current, fragments.hanoi + fragments.ice + fragments.twentyfour)).body.run as Run;
};

beforeAll(async () => {
  await mkdir(join(directory, 'bank'), { recursive: true });
  for (const game of games) {
    const entries = casesOf(game)
      .filter((item) => item.tier === 'entry')
      .map((item) => item.puzzle)
      .concat(game === 'hanoi' ? [towerTwo] : [])
      .map((puzzle, index) => ({ id: `${game}.entry.${index}`, puzzle, expected: 60, difficulty: 4, fragment: fragments[game], minimum: null, slots: slotsOf(game, puzzle as Record<string, unknown>) }));
    // 汉诺塔用带题面写法版本的文件名（题库工具现在这么出）；冰面与 24 点用旧文件名（第 1 版，部署时线上已有的题库）。
    const name = game === 'hanoi' ? `${game}@1.entry.json` : `${game}.entry.json`;
    await writeFile(join(directory, 'bank', name), JSON.stringify(game === 'hanoi' ? { version: 2, puzzleVersion: 1, entries } : { version: 2, entries }));
  }
  await writeConfig(config());
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  database = app.get(DataSource);
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
  await writeConfig(config());
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
    expect(listed.body.challenges).toEqual([expect.objectContaining({ title: '三连环', label: '入门', levels: 3, tiers: ['entry', 'entry', 'entry'], edges: [[0, 2], [1, 2]], timeLimit: 600, best: null, playable: true })]);
    expect(listed.body.challenges[0].id).toMatch(/^weekly\.\d{4}-\d\d-\d\d\.trio$/);
    expect((await list(device, ['hanoi', 'ice'])).body.challenges[0].playable).toBe(false);
    expect((await device.call('POST', `/v1/challenges/${listed.body.challenges[0].id as string}/runs`, { games: ['hanoi', 'ice'] })).body.code).toBe('CHALLENGE_UNAVAILABLE');
    expect((await device.call('POST', '/v1/challenges/weekly.2020-01-06.trio/runs', { games })).body.code).toBe('CHALLENGE_NOT_FOUND');
  });

  // 人工决策见客户端 challenge_rules.dart 的 11-15 19:18 那条：客户端报「游戏@题面写法版本」，服务器只排、只下发认得的版本。
  it('题面写法版本：报「游戏@版本」照常玩，只报游戏名按第 1 版；报了这份判定不认得的版本当玩不了；题库文件写的版本和文件名对不上就不用', async () => {
    const { device } = await signedIn();
    const versioned = ['hanoi@1', 'ice@1', 'twentyfour@1'];
    const listed = await list(device, versioned);
    expect(listed.status).toBe(200);
    expect(listed.body.challenges[0].playable).toBe(true);
    const id = listed.body.challenges[0].id as string;
    expect((await list(device, ['hanoi@9', 'ice@1', 'twentyfour@1'])).body.challenges[0].playable).toBe(false);
    expect((await device.call('POST', `/v1/challenges/${id}/runs`, { games: ['hanoi@9', 'ice@1', 'twentyfour@1'] })).body.code).toBe('CHALLENGE_UNAVAILABLE');
    expect((await device.call('GET', '/v1/challenges?games=hanoi@1x')).status).toBe(400);

    // 冰面多一份写着第 2 版的 ice@1 文件：版本对不上，这一份不用（冰面没题可出），删掉后回到旧文件名的那份。
    const wrong = join(directory, 'bank', 'ice@1.entry.json');
    await writeFile(wrong, JSON.stringify({ version: 2, puzzleVersion: 2, entries: [{ id: 'ice.entry.0', puzzle: vectors.games.ice[0].puzzle, expected: 60, difficulty: 4, fragment: 6, minimum: null, slots: [] }] }));
    expect((await device.call('POST', `/v1/challenges/${id}/runs`, { games: versioned })).body.code).toBe('CHALLENGE_UNAVAILABLE');
    await rm(wrong);
    const started = await device.call('POST', `/v1/challenges/${id}/runs`, { games: versioned });
    expect(started.status, JSON.stringify(started.body)).toBe(200);
    const run = started.body as Run;
    expect(run.levels.map((item) => item.game)).toEqual(['hanoi', 'ice', 'twentyfour']);
    const answered = await solve(device, run, 'a');
    expect(answered.fragment).toBe(fragments.hanoi);
  });

  it('整局走完：错交计数、重发只算一次、过关给一次碎片、碎片齐了到门前、门输错扣 20 秒、重做看碎片、终章输对才算全部过关并记积分', async () => {
    const { device } = await signedIn();
    const started = await start(device);
    expect(started.status).toBe(200);
    let run = started.body as Run;
    expect(run).toMatchObject({ state: 'running', final: 'locked', penaltySeconds: 0 });
    expect(level(run, 'a')).toMatchObject({ game: 'hanoi', state: 'open', letter: 'A', gate: null, consume: null });
    expect(level(run, 'c')).toMatchObject({ game: 'twentyfour', state: 'locked', letter: 'C', puzzle: null, consume: { kind: 'slot', modulus: 9, offset: 1 } });
    expect(level(run, 'c').gate).toEqual({ op: expect.stringMatching(/^(sum|product)$/), value: null });
    expect((await submit(device, run, 'c', [])).body.code).toBe('LEVEL_LOCKED');

    const wrong = await submit(device, run, 'a', []);
    expect(wrong.body).toMatchObject({ correct: false, fragment: null, extra: null });
    // 回复丢了重发同一个号：回原来的结果，不再计数。
    const replay = await submit(device, run, 'a', [], 0);
    expect(replay.body.correct).toBe(false);
    expect(level(replay.body.run as Run, 'a')).toMatchObject({ submissions: 1, errors: 1 });
    run = wrong.body.run as Run;

    const first = await solve(device, run, 'a');
    expect(first.fragment).toBe(fragments.hanoi);
    expect(level(first.run, 'c').state).toBe('locked');
    // 碎片只在过关那次回复里给；过了的关还能拿到题面，重做一遍再看一次碎片（不计错交、不改进度）。
    expect(JSON.stringify(first.run)).not.toContain('"fragment"');
    const again = await solve(device, first.run, 'a');
    expect(again.fragment).toBe(fragments.hanoi);
    expect((await submit(device, again.run, 'a', [])).body).toMatchObject({ correct: false });
    const second = await solve(device, (await device.call('GET', `/v1/challenge-runs/${run.runId}`)).body as Run, 'b');
    expect(level(second.run, 'c').state).toBe('gated');

    const deadline = second.run.deadline;
    const missed = await gate(device, second.run, 'c', gateOf(second.run) + 1);
    expect(missed.body).toMatchObject({ correct: false });
    expect((missed.body.run as Run).penaltySeconds).toBe(20);
    expect((missed.body.run as Run).deadline).toBe(deadline - 20_000);
    expect(level(missed.body.run as Run, 'c').state).toBe('gated');
    const opened = await gate(device, missed.body.run as Run, 'c', gateOf(second.run));
    expect(opened.body.correct).toBe(true);
    const consumer = level(opened.body.run as Run, 'c');
    expect(consumer).toMatchObject({ state: 'open', gate: { value: gateOf(second.run) } });
    // 门上的数 ÷ 9 余数 + 1 = 1：那一处就是题面里的 1。
    expect((consumer.puzzle as { numbers: number[] }).numbers[consumer.consume!.at]).toBe(1);

    const last = await solve(device, opened.body.run as Run, 'c');
    expect(last.run).toMatchObject({ state: 'running', final: 'ready' });
    expect((await final(device, last.run, 1)).body).toMatchObject({ correct: false, run: { penaltySeconds: 40 } });
    const cleared = (await final(device, last.run, fragments.hanoi + fragments.ice + fragments.twentyfour)).body as { correct: boolean; run: Run };
    expect(cleared.correct).toBe(true);
    expect(cleared.run).toMatchObject({ state: 'settled', final: 'cleared', result: { ending: 'cleared' } });
    const { points, awarded } = cleared.run.result!;
    expect(points).toBeGreaterThan(0);
    expect(awarded).toBe(points);
    expect((await device.call('POST', `/v1/challenge-runs/${run.runId}/levels/c/answers`, { attempt: 1, answer: [] })).body.code).toBe('RUN_OVER');
    expect((await gate(device, cleared.run, 'c', 9)).body.code).toBe('RUN_OVER');

    const summary = await device.call('GET', '/v1/points');
    expect(summary.body).toMatchObject({ balance: awarded, expiring: 0, expiringAt: null });
    const entries = await device.call('GET', '/v1/points/entries');
    expect(entries.body.entries).toEqual([expect.objectContaining({ kind: 'earn', amount: awarded, note: '入门 · 三连环' })]);
    expect((await list(device)).body.challenges[0].best).toBe(points);
    // 每过一关记一次用时（分析用的计数，不等它写完）。
    await new Promise((resolve) => setTimeout(resolve, 100));
    const paces = (await database.query('SELECT game, CAST(SUM(count) AS UNSIGNED) AS count FROM challenge_pace GROUP BY game ORDER BY game')) as { game: string; count: string | number }[];
    expect(paces.map((row) => [row.game, Number(row.count)])).toEqual(expect.arrayContaining([['hanoi', expect.any(Number)], ['ice', expect.any(Number)], ['twentyfour', expect.any(Number)]]));

    // 再来一局只过一关就结束：成绩没超过最好成绩，不加积分。
    const next = (await start(device)).body as Run;
    const partial = await solve(device, next, 'a');
    const ended = await device.call('POST', `/v1/challenge-runs/${next.runId}/end`);
    expect(ended.body.result).toMatchObject({ ending: 'ended', awarded: 0 });
    expect(ended.body.result.points).toBeLessThan(points);
    expect(partial.run.state).toBe('running');
    expect((await device.call('GET', '/v1/points')).body.balance).toBe(awarded);
  });

  it('解得快得不正常追加加试题：直接开着、同一个游戏，做完前终章开不了，做完才能输最终密码', async () => {
    const { device } = await signedIn();
    await writeConfig(config({}, { maxExtras: 1 }));
    const run = (await start(device)).body as Run;
    const first = await solve(device, run, 'a');
    expect(first.extra).toBe('xa');
    expect(level(first.run, 'xa')).toMatchObject({ game: 'hanoi', state: 'open', extraOf: 'a', letter: null });
    // 一局最多 1 道：b 再快也不加。
    let current = (await solve(device, first.run, 'b')).run;
    expect(current.levels).toHaveLength(4);
    current = (await gate(device, current, 'c', gateOf(current))).body.run as Run;
    current = (await solve(device, current, 'c')).run;
    expect(current.final).toBe('locked');
    expect((await final(device, current, 34)).body.code).toBe('LEVEL_LOCKED');
    const extra = await solve(device, current, 'xa');
    expect(extra.fragment).toBeNull();
    expect(extra.run.final).toBe('ready');
    expect((await final(device, extra.run, 34)).body.run.result).toMatchObject({ ending: 'cleared' });
    await writeConfig(config());
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
    expect(stuck.fragment).toBe(fragments.ice);
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
    expect((await clear(device, run)).result).toMatchObject({ ending: 'cleared' });
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
    // 早就花完、过期了还留着的一笔：不在到期清零的索引范围里，不再记过期流水。
    await database.query('INSERT INTO points_grant (account_id, amount, remaining, source, source_key, expire_time, create_time, update_time) VALUES (?, 20, 0, ?, ?, ?, ?, ?)', [accountId, 'challenge', `spent-${accountId}`, new Date(now - 3 * 86400_000), old, old]);
    expect((await device.call('GET', '/v1/points')).body).toMatchObject({ balance: 30, expiring: 30 });
    await app.get(PointsRetentionTask).sweep(new Date(now));
    const entries = (await device.call('GET', '/v1/points/entries')).body.entries as { kind: string; amount: number }[];
    expect(entries.filter((entry) => entry.kind === 'expire')).toEqual([expect.objectContaining({ kind: 'expire', amount: -50 })]);
    const ancient = new Date(now - (pointsEntryKeepDays + 1) * 86400_000);
    await database.query('UPDATE points_entry SET create_time = ? WHERE account_id = ?', [ancient, accountId]);
    await app.get(PointsRetentionTask).sweep(new Date(now));
    expect(await database.query('SELECT id FROM points_entry WHERE account_id = ?', [accountId])).toEqual([]);

    const run = (await start(device)).body as Run;
    await device.call('POST', `/v1/challenge-runs/${run.runId}/end`);
    await database.query('UPDATE challenge_run SET end_time = ? WHERE run_id = ?', [new Date(now - (challengeRunKeepDays + 1) * 86400_000), run.runId]);
    // 满 12 周的用时计数一并删掉。
    await database.query("INSERT INTO challenge_pace (game, week, bucket, count, create_time, update_time) VALUES ('hanoi', '2020-01-06', 0, 1, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3)) ON DUPLICATE KEY UPDATE count = count");
    await app.get(ChallengeTasks).sweep(now);
    expect(await database.query('SELECT id FROM challenge_run WHERE run_id = ?', [run.runId])).toEqual([]);
    expect(await database.query("SELECT id FROM challenge_pace WHERE week = '2020-01-06'")).toEqual([]);
  });

  it('要门票的挑战：积分不够不开也不扣；开局先扣快过期的，提前结束不退；等级按获得总数、花了不减', async () => {
    const { device, accountId } = await signedIn();
    await writeConfig(config({ rotations: [{ id: 'weekly', every: 'week', templates: ['trio'] }, { id: 'paid', every: 'week', templates: ['trio'], ticket: 50 }] }));
    const paid = ((await list(device)).body.challenges as { id: string; ticket: number }[]).find((item) => item.id.startsWith('paid.'))!;
    expect(paid.ticket).toBe(50);
    expect(((await list(device)).body.challenges as { ticket: number }[]).map((item) => item.ticket)).toEqual([0, 50]);

    const short = await device.call('POST', `/v1/challenges/${paid.id}/runs`, { games });
    expect(short.status).toBe(409);
    expect(short.body).toMatchObject({ code: 'POINTS_SHORT', price: 50, balance: 0 });
    expect((await list(device)).body.activeRun).toBeNull();

    const now = Date.now();
    const grant = (key: string, amount: number, days: number) =>
      database.query('INSERT INTO points_grant (account_id, amount, remaining, source, source_key, expire_time, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', [
        accountId,
        amount,
        amount,
        'challenge',
        `${key}-${accountId}`,
        new Date(now + days * 86400_000),
        new Date(now),
        new Date(now),
      ]);
    await grant('late', 40, 300);
    await grant('soon', 30, 10);
    const started = await device.call('POST', `/v1/challenges/${paid.id}/runs`, { games });
    expect(started.status, JSON.stringify(started.body)).toBe(200);
    const remaining = (await database.query('SELECT source_key AS sourceKey, remaining FROM points_grant WHERE account_id = ? ORDER BY expire_time', [accountId])) as { sourceKey: string; remaining: number }[];
    expect(remaining.map((row) => row.remaining)).toEqual([0, 20]);
    const entries = (await device.call('GET', '/v1/points/entries')).body.entries as { kind: string; amount: number; note: string }[];
    expect(entries[0]).toMatchObject({ kind: 'spend', amount: -50, note: '入门 · 三连环 门票' });

    expect((await device.call('POST', `/v1/challenge-runs/${(started.body as Run).runId}/end`)).body.state).toBe('settled');
    expect((await device.call('GET', '/v1/points')).body).toMatchObject({ balance: 20, earned: 70, level: 0, nextLevelAt: null });

    // 门槛来自灰度配置：获得 70 分在 [0, 50, 100, ...] 里是 Lv1，离 Lv2 要 100。
    const rollout = join(env().releasesDir, 'rollout.json');
    await writeFile(rollout, JSON.stringify({ flags: [], levels: [0, 50, 100, 200, 400, 800], envelope: null }));
    await utimes(rollout, now / 1000 + 5, now / 1000 + 5);
    expect((await device.call('GET', '/v1/points')).body).toMatchObject({ balance: 20, earned: 70, level: 1, nextLevelAt: 100 });
    await rm(rollout);
    await writeConfig(config());
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
