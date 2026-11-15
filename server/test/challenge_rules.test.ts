import { readFileSync } from 'node:fs';

import { challengeMaxLevels } from 'src/common/relay_limits';
import { periodOf } from 'src/modules/challenge/challenge_calendar';
import { ChallengeConfigError, ChallengeScoring, ChallengeTemplate, parseChallengeConfig } from 'src/modules/challenge/challenge_config';
import { BankEntry } from 'src/modules/challenge/challenge_content';
import { paceBucket, paceFactor } from 'src/modules/challenge/challenge_pace';
import { ChallengePlan, ChallengePlanError, extraLevel, planChallenge, PlanLevel, puzzleDifficulty } from 'src/modules/challenge/challenge_plan';
import { addExtra, finalReady, finalValue, JudgedAnswer, openFinal, openGate, recordVerdict, runOutcome, scoreRun, startProgress } from 'src/modules/challenge/challenge_progress';
import { judgedGames } from 'src/modules/challenge/judges/judges';

const scoring: ChallengeScoring = { levelBase: 10, parSlack: 1.5, gatePenalty: 20, extraRatio: 0.15, extraFloor: 30, maxExtras: 3, timeFloor: 0.4, errorDecay: 0.9, passWeight: 0.5, depthBonus: 0.05, clearBonus: 0.25, timeBonus: 0.2, maxErrors: 3 };
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
  it('仓库里的 challenge/config.json 服务端认得：四个免费模板在每周轮换里，另有一场要门票的加赛', () => {
    const config = parseChallengeConfig(JSON.parse(readFileSync(new URL('../../challenge/config.json', import.meta.url), 'utf8')), judgedGames, challengeMaxLevels);
    expect([...config.templates.keys()]).toEqual(['six', 'eight', 'ten', 'twelve', 'bonus']);
    expect(config.templates.get('twelve')!.nodes).toHaveLength(12);
    expect(config.templates.get('bonus')!.label).toBe('加赛');
    expect(config.rotations).toEqual([
      { id: 'weekly', every: 'week', templates: ['six', 'eight', 'ten', 'twelve'], ticket: 0 },
      { id: 'bonus', every: 'week', templates: ['bonus'], ticket: 300 },
    ]);
  });

  it('门票：不写是免费，写了要是 1–100000 的积分', () => {
    const parse = (ticket: unknown) => () => parseChallengeConfig({ ...rawConfig(twoToOne), rotations: [{ id: 'weekly', every: 'week', templates: ['demo'], ticket }] }, judgedGames, challengeMaxLevels);
    expect(parse(undefined)().rotations[0].ticket).toBe(0);
    expect(parse(300)().rotations[0].ticket).toBe(300);
    expect(parse(0)).toThrow(/ticket/);
    expect(parse('300')).toThrow(/ticket/);
    expect(parse(100_001)).toThrow(/ticket/);
  });

  it('关卡图不合规的拒收：环、一关两条出边、收碎片的不是能收碎片的游戏、给碎片的只放天平称球、关卡 id 不是 a–p 的一个字母、不认识的游戏、边指向不存在的关', () => {
    const parse = (template: Record<string, unknown>) => () => parseChallengeConfig(rawConfig(template), judgedGames, challengeMaxLevels);
    expect(parse(twoToOne)).not.toThrow();
    expect(parse({ ...twoToOne, edges: [['a', 'c'], ['c', 'a']] })).toThrow(ChallengeConfigError);
    expect(parse({ ...twoToOne, edges: [['a', 'b'], ['a', 'c']] })).toThrow(/不止一条出边/);
    expect(parse({ ...twoToOne, nodes: [{ id: 'a', tier: 'entry' }, { id: 'b', tier: 'entry' }, { id: 'c', tier: 'easy', games: ['hanoi', 'flash'] }] })).not.toThrow();
    expect(parse({ ...twoToOne, nodes: [{ id: 'a', tier: 'entry' }, { id: 'b', tier: 'entry' }, { id: 'c', tier: 'easy', games: ['mines'] }] })).toThrow(/收碎片/);
    expect(parse({ ...twoToOne, nodes: [{ id: 'a', tier: 'entry', games: ['balance'] }, { id: 'b', tier: 'entry' }, { id: 'c', tier: 'easy' }] })).toThrow(/给碎片/);
    expect(parse({ ...twoToOne, nodes: [{ id: 'aa', tier: 'entry' }, { id: 'b', tier: 'entry' }, { id: 'c', tier: 'easy' }], edges: [['aa', 'c'], ['b', 'c']] })).toThrow(/关卡 id/);
    expect(parse({ ...twoToOne, nodes: [{ id: 'a', tier: 'entry', games: ['schulte'] }, { id: 'b', tier: 'entry' }, { id: 'c', tier: 'easy' }] })).toThrow(/进不了挑战/);
    expect(parse({ ...twoToOne, edges: [['a', 'z']] })).toThrow(/边/);
    expect(parse({ ...twoToOne, timeLimit: 10 })).toThrow(/timeLimit/);
  });
});

const template = (raw: Record<string, unknown>) => parseChallengeConfig(rawConfig(raw), judgedGames, challengeMaxLevels).templates.get('demo')!;
const entry = (id: string, more: Partial<BankEntry> = {}): BankEntry => ({ id, puzzle: { numbers: [3, 8, 3, 8], ops: [0, 1, 2, 3] }, expected: 60, difficulty: 4, fragment: 5, minimum: null, slots: [], exits: [], ...more });
const sequence = (values: number[]) => {
  let index = 0;
  return (bound: number) => values[index++ % values.length] % bound;
};
const flat = () => 1;

describe('出题、碎片与门', () => {
  const tpl: ChallengeTemplate = template({ ...twoToOne, nodes: [{ id: 'a', tier: 'entry' }, { id: 'b', tier: 'entry' }, { id: 'c', tier: 'easy', games: ['twentyfour'] }] });
  const cards = [1, 2, 3, 4, 5, 6, 7, 8, 9].map((value) => entry(`t${value}`, { puzzle: { numbers: [3, 8, value, 8], ops: [0, 1, 2, 3] }, slots: [{ at: 2, value }] }));
  const bank = async (game: string) => (game === 'twentyfour' ? cards : game === 'hanoi' ? [entry('h', { fragment: 7, puzzle: { disks: 3, start: [0, 0, 0], target: 2 } })] : [entry(game, { fragment: 5 })]);
  const input = { challengeId: 'x', title: '演示', template: tpl, endsAt: 0, scoring, allGames: new Set(['hanoi', 'ice', 'twentyfour']), pace: flat };

  it('给碎片的关带碎片与字母；收碎片的关的门上的数是碎片的和或积，挑的题那一处的真值 = 门上的数 ÷ modulus 的余数 + offset', async () => {
    for (const product of [false, true]) {
      const plan = await planChallenge({ ...input, supported: new Set(['hanoi', 'ice', 'twentyfour']) }, bank, sequence(product ? [0, 0, 0, 0, 0, 0, 0] : [1, 1, 1, 1, 1, 1, 1]));
      const [a, b, c] = plan.levels;
      expect([a.letter, b.letter, c.letter]).toEqual(['A', 'B', 'C']);
      expect(c).toMatchObject({ game: 'twentyfour', inputs: ['a', 'b'], output: null, depth: 1 });
      const fragments = [a.fragment!, b.fragment!];
      expect(c.gate).toEqual({ op: c.gate!.op, value: c.gate!.op === 'product' ? fragments[0] * fragments[1] : fragments[0] + fragments[1] });
      // 简单档的 24 点按 10 取余：挑到的那道第 3 张牌就是门上的数 ÷ 10 的余数 + 1。
      expect(c.consume).toEqual({ kind: 'slot', at: 2, modulus: 10, offset: 1 });
      expect((c.puzzle as { numbers: number[] }).numbers[2]).toBe((c.gate!.value % 10) + 1);
      expect(plan.levels.map((level) => level.expected)).toEqual([60, 60, 60]);
      expect(a.difficulty).toBe(puzzleDifficulty(60));
    }
  });

  it('改目标：汉诺塔轮换柱子让目标柱是第几根，冰面滑行换成第几个出口（碎片、最少步数、预计用时跟着换），记忆闪光余 1 镜像', async () => {
    const goals = template({ nodes: [{ id: 'a', tier: 'hard', games: ['mines'] }, { id: 'b', tier: 'hard', games: ['hanoi', 'ice', 'flash'] }], edges: [['a', 'b']] });
    const ice = entry('i', { puzzle: { width: 6, height: 6, rocks: '0'.repeat(36), start: 0, goal: 35 }, fragment: 4, minimum: 4, exits: [{ cell: 5, minimum: 1, fragment: 1, expected: 30, difficulty: 2 }, { cell: 30, minimum: 1, fragment: 1, expected: 30, difficulty: 2 }, { cell: 35, minimum: 2, fragment: 2, expected: 45, difficulty: 3 }] });
    const hanoi = entry('h', { puzzle: { disks: 3, start: [0, 0, 0], target: 2 }, fragment: 7, minimum: 7 });
    const flash = entry('f', { puzzle: { side: 3, show: 1500, rounds: [[[0, 1, 2]]] } });
    const banks = async (game: string) => (game === 'mines' ? [entry('m', { fragment: 7 })] : game === 'hanoi' ? [hanoi] : game === 'ice' ? [ice] : [flash]);
    const pick = async (game: string) => (await planChallenge({ ...input, template: goals, supported: new Set(['mines', game]), allGames: new Set(['mines', game]) }, banks, sequence([0]))).levels[1];
    // 门上的数是 7：汉诺塔 7 ÷ 3 余 1 → 第 2 根；冰面 7 ÷ 3 余 1 → 第 2 个出口；记忆闪光 7 ÷ 2 余 1 → 镜像。
    const tower = await pick('hanoi');
    expect(tower.consume).toEqual({ kind: 'goal', at: 0, modulus: 3, offset: 1 });
    expect(tower.puzzle).toEqual({ disks: 3, start: [2, 2, 2], target: 1 });
    expect(tower).toMatchObject({ fragment: 7, minimum: 7 });
    const slide = await pick('ice');
    expect(slide.puzzle).toMatchObject({ goal: 30, exits: [5, 30, 35] });
    expect(slide).toMatchObject({ fragment: 1, minimum: 1, baseExpected: 30 });
    expect((await pick('flash')).puzzle).toMatchObject({ mirror: true });
  });

  it('按真实过关用时回调的倍数乘在预计用时上，难度分跟着变；排几次留预计总用时接近限时一半多的那份', async () => {
    const plan = await planChallenge({ ...input, supported: new Set(['hanoi', 'ice', 'twentyfour']), pace: (game) => (game === 'hanoi' ? 2 : 1) }, bank, sequence([0]));
    const hanoi = plan.levels.find((level) => level.game === 'hanoi')!;
    expect(hanoi).toMatchObject({ baseExpected: 60, expected: 120, difficulty: puzzleDifficulty(120) });
  });

  it('挑不出题（客户端玩不了、没有那一处的值对得上门上的数的题）抛 ChallengePlanError', async () => {
    await expect(planChallenge({ ...input, supported: new Set(['hanoi']) }, bank)).rejects.toThrow(ChallengePlanError);
    await expect(planChallenge({ ...input, supported: new Set(['hanoi', 'ice', 'twentyfour']) }, async (game) => (game === 'twentyfour' ? [entry('t', { slots: [{ at: 0, value: 13 }] })] : [entry(game)]))).rejects.toThrow(ChallengePlanError);
  });

  it('加试题同一个游戏另挑一道，不给碎片、不收碎片，编号 xa', async () => {
    const plan = await planChallenge({ ...input, supported: new Set(['hanoi', 'ice', 'twentyfour']) }, bank, sequence([0]));
    const of = plan.levels.find((level) => level.game === 'twentyfour')!;
    const extra = (await extraLevel(plan, of, bank, flat, sequence([0])))!;
    expect(extra).toMatchObject({ id: 'xa', game: 'twentyfour', extraOf: of.id, fragment: null, letter: null, gate: null, consume: null, inputs: [], output: null });
    expect(extra.puzzle).not.toBe(of.puzzle);
  });
});

describe('预计用时的回调', () => {
  it('用时比按 2 的 1/4 次方分档，夹在 1/8 到 8 倍', () => {
    expect([paceBucket(60_000, 60), paceBucket(120_000, 60), paceBucket(30_000, 60), paceBucket(1, 60), paceBucket(10_000_000, 60)]).toEqual([0, 4, -4, -12, 12]);
  });

  it('次数不够 30 次不回调；够了取中位数所在的档，夹在 1/2 到 2 倍', () => {
    expect(paceFactor(new Map([[4, 29]]))).toBe(1);
    expect(paceFactor(new Map([[4, 20], [0, 10]]))).toBe(2);
    expect(paceFactor(new Map([[-2, 16], [8, 15]]))).toBeCloseTo(2 ** -0.5);
    expect(paceFactor(new Map([[12, 40]]))).toBe(2);
    expect(paceFactor(new Map([[-12, 40]]))).toBe(0.5);
  });
});

describe('进度与计分', () => {
  const level = (more: Partial<PlanLevel> & Pick<PlanLevel, 'id'>): PlanLevel => ({ game: 'hanoi', tier: 'entry', baseExpected: 60, expected: 60, difficulty: 4, puzzle: null, inputs: [], output: null, fragment: 3, letter: null, minimum: null, gate: null, consume: null, depth: 0, extraOf: null, ...more });
  const plan = (expected: number[]): ChallengePlan => ({
    version: 2,
    challengeId: 'x',
    title: '演示',
    label: '入门',
    timeLimit: 600,
    endsAt: 0,
    scoring,
    levels: [
      level({ id: 'a', expected: expected[0], difficulty: puzzleDifficulty(expected[0]), output: 'c', fragment: 3, letter: 'A' }),
      level({ id: 'b', game: 'ice', expected: expected[1], difficulty: puzzleDifficulty(expected[1]), output: 'c', fragment: 8, letter: 'B' }),
      level({ id: 'c', game: 'twentyfour', tier: 'easy', expected: expected[2], difficulty: puzzleDifficulty(expected[2]), inputs: ['a', 'b'], fragment: 20, letter: 'C', gate: { op: 'product', value: 24 }, consume: { kind: 'slot', at: 0, modulus: 10, offset: 1 }, depth: 1 }),
    ],
  });
  const yes: JudgedAnswer = { solved: true, penalties: 0, steps: null, answerFragment: null };
  const no: JudgedAnswer = { solved: false, penalties: 0, steps: null, answerFragment: null };

  it('碎片齐了到门前；门上的数对了才开，输错扣 20 秒；全过了终章才能输，最终密码 = 全部碎片之和，输对是 cleared', () => {
    const demo = plan([60, 60, 60]);
    const progress = startProgress(demo, 0);
    expect(Object.values(progress.levels).map((item) => item.state)).toEqual(['open', 'open', 'locked']);
    expect(recordVerdict(demo, progress, 'a', yes, 1000)).toEqual({ solved: true, fragment: 3, replay: false });
    expect(progress.levels.c.state).toBe('locked');
    recordVerdict(demo, progress, 'b', no, 2000);
    expect(progress.levels.b).toMatchObject({ state: 'open', errors: 1, submissions: 1 });
    recordVerdict(demo, progress, 'b', yes, 3000);
    expect(progress.levels.c.state).toBe('gated');
    expect(runOutcome(demo, progress)).toBeNull();
    expect(openGate(demo, progress, 'c', 11, 3500)).toBe(false);
    expect(progress.penaltySeconds).toBe(20);
    expect(openGate(demo, progress, 'c', 24, 4000)).toBe(true);
    expect(progress.levels.c).toMatchObject({ state: 'open', openedAt: 4000 });
    expect(finalReady(demo, progress)).toBe(false);
    recordVerdict(demo, progress, 'c', yes, 5000);
    expect(finalReady(demo, progress)).toBe(true);
    expect(finalValue(demo, progress)).toBe(3 + 8 + 20);
    expect(runOutcome(demo, progress)).toBeNull();
    expect(openFinal(demo, progress, 30)).toBe(false);
    expect(progress.penaltySeconds).toBe(40);
    expect(openFinal(demo, progress, 31)).toBe(true);
    expect(runOutcome(demo, progress)).toBe('cleared');
  });

  it('重做过了的关：对了再给一次碎片、不改进度，错了不计错交；要最少步数的多一步不算过；天平称球的碎片按答案给', () => {
    const demo = plan([60, 60, 60]);
    demo.levels[0].minimum = 7;
    const progress = startProgress(demo, 0);
    expect(recordVerdict(demo, progress, 'a', { ...yes, steps: 8 }, 1000).solved).toBe(false);
    expect(progress.levels.a).toMatchObject({ state: 'open', errors: 1 });
    recordVerdict(demo, progress, 'a', { ...yes, steps: 7 }, 2000);
    expect(recordVerdict(demo, progress, 'a', { ...yes, steps: 7 }, 9000)).toEqual({ solved: true, fragment: 3, replay: true });
    expect(recordVerdict(demo, progress, 'a', no, 9500)).toEqual({ solved: false, fragment: null, replay: true });
    expect(progress.levels.a).toMatchObject({ state: 'solved', solvedAt: 2000, errors: 1 });

    const balance = plan([60, 60, 60]);
    balance.levels[1] = level({ id: 'b', game: 'balance', fragment: null, letter: 'B' });
    const weighed = startProgress(balance, 0);
    recordVerdict(balance, weighed, 'b', { ...yes, answerFragment: 6 }, 1000);
    expect(weighed.levels.b.fragment).toBe(6);
  });

  it('加试题直接开着，做完前终章开不了，不给碎片也不计分；错交到上限算没过、剩下的开不了是 stuck', () => {
    const demo = plan([60, 60, 60]);
    const progress = startProgress(demo, 0);
    recordVerdict(demo, progress, 'a', yes, 1000);
    addExtra(demo, progress, level({ id: 'xa', fragment: null, extraOf: 'a' }), 1000);
    expect(progress.levels.xa.state).toBe('open');
    recordVerdict(demo, progress, 'b', yes, 2000);
    openGate(demo, progress, 'c', 24, 2000);
    recordVerdict(demo, progress, 'c', yes, 3000);
    expect(finalReady(demo, progress)).toBe(false);
    expect(recordVerdict(demo, progress, 'xa', yes, 4000).fragment).toBeNull();
    expect(finalReady(demo, progress)).toBe(true);
    expect(finalValue(demo, progress)).toBe(31);
    expect(Object.keys(scoreRun(demo, progress, 4000, 600_000).levels)).toEqual(['a', 'b', 'c']);

    const failing = startProgress(demo, 0);
    for (let round = 0; round < scoring.maxErrors; round++) recordVerdict(demo, failing, 'a', no, 1000);
    expect(failing.levels.a.state).toBe('failed');
    expect(runOutcome(demo, failing)).toBeNull();
    recordVerdict(demo, failing, 'b', yes, 2000);
    recordVerdict(demo, failing, 'xa', yes, 2000);
    expect(runOutcome(demo, failing)).toBe('stuck');
  });

  it('计分按口径：参考用时 = 预计用时 × 1.5，分段用时、时间系数夹在 0.4–1、错交衰减、串联加成、过关率，终章输对才有全通关奖励', () => {
    // 预计 60、60、240 秒：难度 4、4、6；参考用时 90、90、360 秒。
    const demo = plan([60, 60, 240]);
    const progress = startProgress(demo, 0);
    recordVerdict(demo, progress, 'a', yes, 60_000); // 60 秒，快于参考：系数 1 → 40
    recordVerdict(demo, progress, 'b', no, 100_000);
    recordVerdict(demo, progress, 'b', yes, 240_000); // 分段从 60 秒算起，180 秒：系数 0.5、错交一次 → 4×10×0.5×0.9 = 18
    openGate(demo, progress, 'c', 24, 240_000);
    recordVerdict(demo, progress, 'c', { ...yes, penalties: 1 }, 1_240_000); // 1000 秒：系数 0.4 封底，失误 1 次、第 1 层 → 6×10×0.4×0.9×1.05 = 22.68
    const sum = 40 + 18 + 22.68;
    // 全过但没输终章：×（1 − 0.5 + 0.5 × 1）= 1，没有全通关奖励。
    expect(scoreRun(demo, progress, 1_240_000, 600_000)).toEqual({ points: Math.round(sum), passRate: 1, cleared: false, levels: { a: 40, b: 18, c: 23 } });
    openFinal(demo, progress, 31);
    // 输对终章：到点已过，剩余时间奖励 0：×1.25。
    expect(scoreRun(demo, progress, 1_240_000, 600_000).points).toBe(Math.round(sum * 1.25));

    const quick = startProgress(demo, 0);
    recordVerdict(demo, quick, 'a', yes, 10_000);
    recordVerdict(demo, quick, 'b', yes, 20_000);
    openGate(demo, quick, 'c', 24, 20_000);
    recordVerdict(demo, quick, 'c', yes, 200_000);
    openFinal(demo, quick, 31);
    // 到点 600 秒（门没输错），在 300 秒结算：剩一半 ×（1 + 0.25 + 0.2 × 0.5）。
    expect(scoreRun(demo, quick, 300_000, 600_000).points).toBe(Math.round((40 + 40 + 60 * 1.05) * 1.35));
  });
});
