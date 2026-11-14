import { readFileSync } from 'node:fs';

import { challengeMaxLevels } from 'src/common/relay_limits';
import { periodOf } from 'src/modules/challenge/challenge_calendar';
import { ChallengeConfigError, ChallengeScoring, ChallengeTemplate, parseChallengeConfig } from 'src/modules/challenge/challenge_config';
import { BankEntry } from 'src/modules/challenge/challenge_content';
import { ChallengePlan, ChallengePlanError, planChallenge, teaserOf } from 'src/modules/challenge/challenge_plan';
import { recordVerdict, runOutcome, scoreRun, startProgress } from 'src/modules/challenge/challenge_progress';
import { judgedGames } from 'src/modules/challenge/judges/judges';

const scoring: ChallengeScoring = { levelBase: 10, timeFloor: 0.4, errorDecay: 0.9, passWeight: 0.5, depthBonus: 0.05, clearBonus: 0.25, timeBonus: 0.2, maxErrors: 3 };
const rawConfig = (template: Record<string, unknown>) => ({ version: 1, scoring, templates: { demo: { title: '演示', label: '入门', timeLimit: 600, ...template } }, rotations: [{ id: 'weekly', every: 'week', templates: ['demo'] }] });
const twoToOne = { nodes: [{ id: 'a', tier: 'entry' }, { id: 'b', tier: 'entry' }, { id: 'c', tier: 'easy' }], edges: [['a', 'c'], ['b', 'c']] };

describe('业务时区的周期', () => {
  it('每周从当地周一 0 点起（北京时间），编号用那天的当地日期', () => {
    const saturday = Date.parse('2026-11-14T05:00:00Z');
    expect(periodOf(saturday, 'week', 'Asia/Shanghai')).toEqual({ start: Date.parse('2026-11-08T16:00:00Z'), end: Date.parse('2026-11-15T16:00:00Z'), date: '2026-11-09' });
    // 周日 23:59 还在这一周，周一 0 点是下一周。
    expect(periodOf(Date.parse('2026-11-15T15:59:00Z'), 'week', 'Asia/Shanghai').date).toBe('2026-11-09');
    expect(periodOf(Date.parse('2026-11-15T16:00:00Z'), 'week', 'Asia/Shanghai').date).toBe('2026-11-16');
    // UTC 已是周一、北京时间还在周一：不按 UTC 日界算。
    expect(periodOf(Date.parse('2026-11-08T20:00:00Z'), 'week', 'Asia/Shanghai').date).toBe('2026-11-09');
  });

  it('夏令时切换那天按当地日界（那一天只有 23 小时）', () => {
    expect(periodOf(Date.parse('2026-03-08T12:00:00Z'), 'day', 'America/New_York')).toEqual({ start: Date.parse('2026-03-08T05:00:00Z'), end: Date.parse('2026-03-09T04:00:00Z'), date: '2026-03-08' });
  });
});

describe('挑战配置', () => {
  it('仓库里的 challenge/config.json 服务端认得，四个模板都在每周轮换里', () => {
    const config = parseChallengeConfig(JSON.parse(readFileSync(new URL('../../challenge/config.json', import.meta.url), 'utf8')), judgedGames, challengeMaxLevels);
    expect([...config.templates.keys()]).toEqual(['six', 'eight', 'ten', 'twelve']);
    expect(config.templates.get('twelve')!.nodes).toHaveLength(12);
    expect(config.rotations).toEqual([{ id: 'weekly', every: 'week', templates: ['six', 'eight', 'ten', 'twelve'] }]);
  });

  it('关卡图不合规的拒收：环、一关两条出边、收钥匙的不是能收钥匙的游戏、不认识的游戏、边指向不存在的关', () => {
    const parse = (template: Record<string, unknown>) => () => parseChallengeConfig(rawConfig(template), judgedGames, challengeMaxLevels);
    expect(parse(twoToOne)).not.toThrow();
    expect(parse({ ...twoToOne, edges: [['a', 'c'], ['c', 'a']] })).toThrow(ChallengeConfigError);
    expect(parse({ ...twoToOne, edges: [['a', 'b'], ['a', 'c']] })).toThrow(/不止一条出边/);
    expect(parse({ ...twoToOne, nodes: [{ id: 'a', tier: 'entry' }, { id: 'b', tier: 'entry' }, { id: 'c', tier: 'easy', games: ['hanoi'] }] })).toThrow(/收钥匙/);
    expect(parse({ ...twoToOne, nodes: [{ id: 'a', tier: 'entry', games: ['schulte'] }, { id: 'b', tier: 'entry' }, { id: 'c', tier: 'easy' }] })).toThrow(/进不了挑战/);
    expect(parse({ ...twoToOne, edges: [['a', 'z']] })).toThrow(/边/);
    expect(parse({ ...twoToOne, timeLimit: 10 })).toThrow(/timeLimit/);
  });
});

const template = (raw: Record<string, unknown>) => parseChallengeConfig(rawConfig(raw), judgedGames, challengeMaxLevels).templates.get('demo')!;
const entry = (id: string, slots: { at: number; value: number; key: number }[] = []): BankEntry => ({ id, puzzle: { numbers: [3, 8, 3, 8], ops: [0, 1, 2, 3] }, difficulty: 2, slots });
const sequence = (values: number[]) => {
  let index = 0;
  return (bound: number) => values[index++ % values.length] % bound;
};

describe('出题与钥匙', () => {
  const tpl: ChallengeTemplate = template(twoToOne);
  const bank = async (game: string) => (game === 'twentyfour' ? [entry('t', [0, 1, 2, 3].map((at) => ({ at, value: [3, 8, 3, 8][at], key: [3, 8, 3, 8][at] })))] : [entry(game)]);

  it('收钥匙的关挖掉几处、给钥匙的关拿到的就是那一处的钥匙；游戏尽量不重复；预告把挖掉的写成 ?', async () => {
    const plan = await planChallenge({ challengeId: 'x', title: '演示', template: tpl, endsAt: 0, scoring, supported: new Set(['hanoi', 'ice', 'twentyfour']), allGames: new Set(['hanoi', 'ice', 'twentyfour']) }, bank, sequence([0, 0, 0, 0, 1, 0]));
    const [a, b, c] = plan.levels;
    expect(c).toMatchObject({ game: 'twentyfour', inputs: ['a', 'b'], output: null, key: null, depth: 1 });
    expect(new Set(plan.levels.map((level) => level.game)).size).toBe(3);
    expect(c.slots.map((slot) => slot.from)).toEqual(['a', 'b']);
    expect(a.key).toBe(c.slots[0].key);
    expect(b.key).toBe(c.slots[1].key);
    expect(new Set(c.slots.map((slot) => slot.at)).size).toBe(2);
    expect(teaserOf(c, () => false)!.split('?').length - 1).toBe(2);
    // 拿到第一把钥匙后，那个位置写钥匙数。
    const known = teaserOf(c, (levelId) => levelId === 'a')!;
    expect(known.split('?').length - 1).toBe(1);
    expect(known).toContain(String(a.key));
    expect(teaserOf(a, () => true)).toBeNull();
  });

  it('挑不出题（客户端玩不了、题库里挖不出足够多处）抛 ChallengePlanError', async () => {
    const input = { challengeId: 'x', title: '演示', template: tpl, endsAt: 0, scoring, allGames: new Set(['hanoi', 'twentyfour']) };
    await expect(planChallenge({ ...input, supported: new Set(['hanoi']) }, bank)).rejects.toThrow(ChallengePlanError);
    await expect(planChallenge({ ...input, supported: new Set(['hanoi', 'twentyfour']) }, async (game) => [entry(game, [{ at: 0, value: 3, key: 3 }])])).rejects.toThrow(ChallengePlanError);
  });
});

describe('进度与计分', () => {
  const plan = (difficulties: number[]): ChallengePlan => ({
    challengeId: 'x',
    title: '演示',
    label: '入门',
    timeLimit: 600,
    endsAt: 0,
    scoring,
    levels: [
      { id: 'a', game: 'hanoi', tier: 'entry', difficulty: difficulties[0], puzzle: null, inputs: [], output: 'c', key: 3, slots: [], depth: 0 },
      { id: 'b', game: 'ice', tier: 'entry', difficulty: difficulties[1], puzzle: null, inputs: [], output: 'c', key: 8, slots: [], depth: 0 },
      { id: 'c', game: 'twentyfour', tier: 'easy', difficulty: difficulties[2], puzzle: null, inputs: ['a', 'b'], output: null, key: null, slots: [], depth: 1 },
    ],
  });

  it('钥匙齐了才解锁；错交到上限算没过、剩下的开不了是 stuck；全过是 cleared', () => {
    const demo = plan([2, 2, 2]);
    const progress = startProgress(demo, 0);
    expect(Object.values(progress.levels).map((level) => level.state)).toEqual(['open', 'open', 'locked']);
    recordVerdict(demo, progress, 'a', true, 0, 1000);
    expect(progress.levels.c.state).toBe('locked');
    recordVerdict(demo, progress, 'b', false, 0, 2000);
    expect(progress.levels.b).toMatchObject({ state: 'open', errors: 1, submissions: 1 });
    recordVerdict(demo, progress, 'b', true, 0, 3000);
    expect(progress.levels.c).toMatchObject({ state: 'open', openedAt: 3000 });
    expect(runOutcome(progress)).toBeNull();
    recordVerdict(demo, progress, 'c', true, 0, 4000);
    expect(runOutcome(progress)).toBe('cleared');

    const failing = startProgress(demo, 0);
    for (let round = 0; round < scoring.maxErrors; round++) recordVerdict(demo, failing, 'a', false, 0, 1000);
    expect(failing.levels.a.state).toBe('failed');
    expect(runOutcome(failing)).toBeNull();
    recordVerdict(demo, failing, 'b', true, 0, 2000);
    expect(runOutcome(failing)).toBe('stuck');
  });

  it('计分按口径：分段用时、时间系数夹在 0.4–1、错交衰减、串联加成、过关率与全通关奖励', () => {
    // 难度 2、2、6：参考用时 120、120、360 秒。
    const demo = plan([2, 2, 6]);
    const progress = startProgress(demo, 0);
    recordVerdict(demo, progress, 'a', true, 0, 60_000); // 用时 60 秒，快于参考：系数 1 → 20
    recordVerdict(demo, progress, 'b', false, 0, 100_000);
    recordVerdict(demo, progress, 'b', true, 0, 300_000); // 分段从 60 秒算起，240 秒：系数 0.5、错交一次 → 2×10×0.5×0.9 = 9
    recordVerdict(demo, progress, 'c', true, 1, 1_200_000); // 900 秒：系数 0.4 封底，答案里失误 1 次、第 1 层 → 6×10×0.4×0.9×1.05 = 22.68
    const sum = 20 + 9 + 22.68;
    // 全过：×（1 − 0.5 + 0.5 × 1）= 1；到点是 600 秒，已超时，剩余时间奖励 0：×1.25。
    expect(scoreRun(demo, progress, 1_200_000)).toEqual({ points: Math.round(sum * 1.25), passRate: 1, cleared: true, levels: { a: 20, b: 9, c: 23 } });

    const partial = startProgress(demo, 0);
    recordVerdict(demo, partial, 'a', true, 0, 30_000);
    // 只过 a：20 ×（0.5 + 0.5 × 2/10）= 12。
    expect(scoreRun(demo, partial, 600_000)).toMatchObject({ points: 12, cleared: false, passRate: 0.2 });

    const quick = startProgress(demo, 0);
    for (const [id, at] of [['a', 10_000], ['b', 20_000], ['c', 300_000]] as const) recordVerdict(demo, quick, id, true, 0, at);
    // 剩 300 秒占一半：×（1 + 0.25 + 0.2 × 0.5）。c 的分段 280 秒、参考 360 秒：系数 1。
    expect(scoreRun(demo, quick, 300_000).points).toBe(Math.round((20 + 20 + 60 * 1.05) * 1.35));
  });
});
