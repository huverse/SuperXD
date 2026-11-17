import { randomInt } from 'node:crypto';

import { ChallengeScoring, ChallengeTemplate, ChallengeTier, consumerGames, optimalGames, optimalTiers } from 'src/modules/challenge/challenge_config';
import { BankEntry } from 'src/modules/challenge/challenge_content';

// 一局开始时排好的计划（人工决策见客户端 lib/playground/challenge/challenge_rules.dart 的 11-14 23:11 那条）：每关是哪个游戏、哪道题、
// 过关给的碎片；收碎片的关前面的门（几关碎片相加或相乘）与门上的数改写这一关的哪一处。计划连同题面整份存进这一局（题库热更新也不影响进行中的局），
// 中途追加的加试题也写进计划。

// 门：门上的数 = inputs 几关碎片的和或积（只有一关就是那个碎片），开局时就算好（给碎片的关碎片都在题库里）。
export type PlanGate = { op: 'sum' | 'product'; value: number };

// 门上的数改写的那一处：slot 是补条件（题面里那一处写成 ?），goal 是改目标（汉诺塔的目标柱、冰面滑行的真出口、记忆闪光要不要镜像）；
// at 是位置（slot 才有意义），值 = 门上的数 ÷ modulus 的余数 + offset（八皇后的列、汉诺塔的柱、冰面的出口都从 1 数）。
export type PlanConsume = { kind: 'slot' | 'goal'; at: number; modulus: number; offset: number };

export type PlanLevel = {
  id: string;
  game: string;
  tier: ChallengeTier;
  // 题面写法版本（客户端报的那一版，判定按它；11-15 以前排的局没有，按第 1 版）。
  version?: number;
  // 题库里的预计用时（秒）与按真实过关用时回调后的预计用时、难度分（计分与参考用时用回调后的）。
  baseExpected: number;
  expected: number;
  difficulty: number;
  puzzle: unknown;
  // 收哪几关的碎片（边的顺序），没有为空。
  inputs: string[];
  // 碎片进哪一关的门，没有（最后一关、加试题）为 null。
  output: string | null;
  // 过关给的碎片与它的字母（A、B…，加试题没有）。
  fragment: number | null;
  letter: string | null;
  // 要用最少步数时的最少步数，不要求为 null。
  minimum: number | null;
  gate: PlanGate | null;
  consume: PlanConsume | null;
  // 从源头数第几层（串联深度，计分用）。
  depth: number;
  // 加试题是为哪一关加的，平常为 null。
  extraOf: string | null;
};

export type ChallengePlan = { version: 2; challengeId: string; title: string; label: string; timeLimit: number; endsAt: number; scoring: ChallengeScoring; levels: PlanLevel[] };

export class ChallengePlanError extends Error {}

// 随机源可注入（测试固定）；默认用密码学随机数，玩家猜不到下一局的题。
export type PlanRandom = (bound: number) => number;
const secureRandom: PlanRandom = (bound) => randomInt(bound);

const pick = <T>(items: T[], random: PlanRandom) => items[random(items.length)];

// 预计用时换难度分（同客户端 puzzle_rules.dart 的 puzzleDifficulty）：10 秒以内 1 分，往后每翻一倍加 1.4 分，夹在 1–10。
export const puzzleDifficulty = (seconds: number) => (seconds <= 10 ? 1 : Math.min(10, Math.max(1, Math.round((1.4 * Math.log(seconds / 10)) / Math.LN2))));

// 门上的数改写这一关的规矩：每个能收碎片的游戏、每档的 modulus 与 offset（值的范围要落在题库里常见的值上，否则挑不出对得上的题），
// 以及这道题里哪几处能改成哪个值（candidates：at 与值）。改不了（冰面滑行没标出口）为 null。
type ConsumeRule = { kind: 'slot' | 'goal'; modulus: number; offset: number; candidates: { at: number; value: number }[] };

// 汉诺塔第 2 版（客户端 hanoi_rules.dart 的 puzzleVersion 2）能改目标柱的题：目标是全部叠到一根柱上，且轮换柱子不改最少步数
// （经典与循环的挪法轮换后照旧，相邻的两头不相连、轮换就变了）。
const hanoiTurnable = (puzzle: Record<string, unknown>) => (puzzle.variant as number) !== 1 && new Set(puzzle.goal as number[]).size === 1;

const consumeRuleOf = (game: string, tier: ChallengeTier, entry: BankEntry, version: number): ConsumeRule | null => {
  const puzzle = entry.puzzle as Record<string, unknown>;
  switch (game) {
    case 'twentyfour': {
      const modulus = tier === 'entry' ? 9 : tier === 'easy' ? 10 : 13;
      return { kind: 'slot', modulus, offset: 1, candidates: entry.slots };
    }
    case 'queens':
      return { kind: 'slot', modulus: puzzle.size as number, offset: 1, candidates: entry.slots.map((slot) => ({ at: slot.at, value: slot.value + 1 })) };
    case 'loop':
      return { kind: 'slot', modulus: 4, offset: 0, candidates: entry.slots };
    case 'cipher':
      return { kind: 'slot', modulus: 3, offset: 0, candidates: entry.slots };
    case 'knights':
      return { kind: 'slot', modulus: (puzzle.claims as unknown[]).length - 1, offset: 1, candidates: entry.slots };
    case 'hanoi': {
      if (version === 1) return { kind: 'goal', modulus: 3, offset: 1, candidates: [1, 2, 3].map((value) => ({ at: 0, value })) };
      if (!hanoiTurnable(puzzle)) return null;
      const pegs = puzzle.pegs as number;
      return { kind: 'goal', modulus: pegs, offset: 1, candidates: Array.from({ length: pegs }, (_, index) => ({ at: 0, value: index + 1 })) };
    }
    case 'ice':
      return entry.exits.length < 2 ? null : { kind: 'goal', modulus: entry.exits.length, offset: 1, candidates: entry.exits.map((_, index) => ({ at: 0, value: index + 1 })) };
    case 'flash':
      return { kind: 'goal', modulus: 2, offset: 0, candidates: [0, 1].map((value) => ({ at: 0, value })) };
    default:
      return null;
  }
};

// 按改目标的值改写题面（返回新题面、这一关的碎片、最少步数与题库预计用时）：汉诺塔把柱子轮换到目标柱是第 value 根（最少步数不变；
// 第 2 版开局与目标一起轮换，按这道题的柱子数），冰面滑行把终点换成第 value 个出口（碎片、最少步数与预计用时都换成那个出口的），记忆闪光 value 为 1 时镜像。
const applyGoal = (game: string, entry: BankEntry, value: number, version: number) => {
  const puzzle = { ...(entry.puzzle as Record<string, unknown>) };
  switch (game) {
    case 'hanoi': {
      if (version === 1) {
        const shift = (value - 1 - (puzzle.target as number) + 3) % 3;
        puzzle.start = (puzzle.start as number[]).map((peg) => (peg + shift) % 3);
        puzzle.target = value - 1;
      } else {
        const pegs = puzzle.pegs as number, shift = (value - 1 - (puzzle.goal as number[])[0] + pegs) % pegs;
        puzzle.start = (puzzle.start as number[]).map((peg) => (peg + shift) % pegs);
        puzzle.goal = (puzzle.goal as number[]).map((peg) => (peg + shift) % pegs);
      }
      return { puzzle, fragment: entry.fragment, minimum: entry.minimum, expected: entry.expected };
    }
    case 'ice': {
      const exit = entry.exits[value - 1];
      puzzle.goal = exit.cell;
      puzzle.exits = entry.exits.map((item) => item.cell);
      return { puzzle, fragment: exit.fragment, minimum: exit.minimum, expected: exit.expected };
    }
    default:
      if (value === 1) puzzle.mirror = true;
      return { puzzle, fragment: entry.fragment, minimum: entry.minimum, expected: entry.expected };
  }
};

const valueOf = (gate: PlanGate, consume: { modulus: number; offset: number }) => (gate.value % consume.modulus) + consume.offset;

type PlanInput = {
  challengeId: string;
  title: string;
  template: ChallengeTemplate;
  endsAt: number;
  scoring: ChallengeScoring;
  // 客户端玩得了的游戏 → 它认得的题面写法版本（只从这一版的题库里出题）。
  supported: ReadonlyMap<string, number>;
  allGames: Set<string>;
  // 这个游戏的预计用时按真实过关用时回调的倍数（见 challenge_pace.ts），没有数据时为 1。
  pace: (game: string) => number;
};

type Bank = (game: string, tier: ChallengeTier, version: number) => Promise<BankEntry[]>;

// 排一次：拓扑序（先排给碎片的关）逐关挑游戏与题。游戏只在客户端玩得了（supported）且题库里有这一档、这一版写法的里挑，尽量不重复；
// 给碎片的关不放碎片要看答案的游戏；收碎片的关先算门上的数，只挑改得出那个值的题。挑不出来抛 ChallengePlanError。
const planOnce = async (input: PlanInput, bank: Bank, random: PlanRandom): Promise<ChallengePlan> => {
  const { template } = input;
  const inputsOf = (id: string) => template.edges.filter(([, to]) => to === id).map(([from]) => from);
  const outputOf = (id: string) => template.edges.find(([from]) => from === id)?.[1] ?? null;
  const depth = new Map<string, number>();
  const depthOf = (id: string): number => {
    const known = depth.get(id);
    if (known !== undefined) return known;
    const value = Math.max(-1, ...inputsOf(id).map(depthOf)) + 1;
    depth.set(id, value);
    return value;
  };
  const used = new Set<string>();
  const levels = new Map<string, PlanLevel>();
  const letters = new Map(template.nodes.map((node, index) => [node.id, String.fromCharCode(65 + index)]));
  for (const node of [...template.nodes].sort((left, right) => depthOf(left.id) - depthOf(right.id))) {
    const inputs = inputsOf(node.id);
    const output = outputOf(node.id);
    let gate: PlanGate | null = null;
    if (inputs.length > 0) {
      const fragments = inputs.map((from) => levels.get(from)!.fragment!);
      const op = inputs.length === 2 && random(2) === 0 ? 'product' : 'sum';
      gate = { op, value: op === 'product' ? fragments.reduce((left, right) => left * right, 1) : fragments.reduce((left, right) => left + right, 0) };
    }
    const pool = (node.games ?? [...(inputs.length > 0 ? consumerGames : input.allGames)]).filter((game) => input.supported.has(game));
    const candidates: { game: string; entries: { entry: BankEntry; rule: ConsumeRule | null; at: number; value: number }[] }[] = [];
    for (const game of pool) {
      const choices = [];
      for (const entry of await bank(game, node.tier, input.supported.get(game)!)) {
        if (gate === null) {
          choices.push({ entry, rule: null, at: 0, value: 0 });
          continue;
        }
        const rule = consumeRuleOf(game, node.tier, entry, input.supported.get(game)!);
        if (rule === null) continue;
        const value = valueOf(gate, rule);
        for (const candidate of rule.candidates) if (candidate.value === value) choices.push({ entry, rule, at: candidate.at, value });
      }
      if (choices.length > 0) candidates.push({ game, entries: choices });
    }
    if (candidates.length === 0) throw new ChallengePlanError(`${template.id} 的 ${node.id} 挑不出题`);
    // 先挑这一局还没用过的；不收碎片的关再优先挑不能收碎片的游戏，把能收碎片的留给收碎片的关。
    const fresh = candidates.filter((candidate) => !used.has(candidate.game));
    const plain = inputs.length === 0 ? fresh.filter((candidate) => !consumerGames.has(candidate.game)) : [];
    const chosen = pick(plain.length > 0 ? plain : fresh.length > 0 ? fresh : candidates, random);
    used.add(chosen.game);
    const { entry, rule, at, value } = pick(chosen.entries, random);
    const goal = rule?.kind === 'goal' ? applyGoal(chosen.game, entry, value, input.supported.get(chosen.game)!) : { puzzle: entry.puzzle, fragment: entry.fragment, minimum: entry.minimum, expected: entry.expected };
    const expected = Math.max(1, Math.round(goal.expected * input.pace(chosen.game)));
    levels.set(node.id, {
      id: node.id,
      game: chosen.game,
      tier: node.tier,
      version: input.supported.get(chosen.game)!,
      baseExpected: goal.expected,
      expected,
      difficulty: puzzleDifficulty(expected),
      puzzle: goal.puzzle,
      inputs,
      output,
      fragment: goal.fragment,
      letter: letters.get(node.id)!,
      minimum: optimalGames.has(chosen.game) && optimalTiers.has(node.tier) ? goal.minimum : null,
      gate,
      consume: rule === null ? null : { kind: rule.kind, at, modulus: rule.modulus, offset: rule.offset },
      depth: depthOf(node.id),
      extraOf: null,
    });
  }
  return {
    version: 2,
    challengeId: input.challengeId,
    title: input.title,
    label: template.label,
    timeLimit: template.timeLimit,
    endsAt: input.endsAt,
    scoring: input.scoring,
    levels: template.nodes.map((node) => levels.get(node.id)!),
  };
};

// 按模板排一局：排几次，留预计总用时最接近限时一半多一点（planTarget）的那份，不超过限时的 planCeiling（一个人一次做一关，总用时就是各关之和）；
// 都超了留最短的。挑不出来（配置与题库对不上、客户端太旧）抛 ChallengePlanError。
const planTries = 12, planTarget = 0.55, planCeiling = 0.8;

export const planChallenge = async (input: PlanInput, bank: Bank, random: PlanRandom = secureRandom): Promise<ChallengePlan> => {
  const limit = input.template.timeLimit;
  let best: { plan: ChallengePlan; miss: number } | null = null;
  for (let attempt = 0; attempt < planTries; attempt++) {
    const plan = await planOnce(input, bank, random);
    const total = plan.levels.reduce((sum, level) => sum + level.expected, 0);
    const miss = total > limit * planCeiling ? limit + total : Math.abs(total - limit * planTarget);
    if (best === null || miss < best.miss) best = { plan, miss };
  }
  return best!.plan;
};

// 加试题：同一个游戏、同一档、同一版题面写法里另挑一道（不改写、不给碎片、不收碎片），编号 xa、xb、xc。
export const extraLevel = async (plan: ChallengePlan, of: PlanLevel, bank: Bank, pace: (game: string) => number, random: PlanRandom = secureRandom): Promise<PlanLevel | null> => {
  const version = of.version ?? 1;
  const entries = (await bank(of.game, of.tier, version)).filter((entry) => JSON.stringify(entry.puzzle) !== JSON.stringify(of.puzzle));
  if (entries.length === 0) return null;
  const entry = pick(entries, random);
  const expected = Math.max(1, Math.round(entry.expected * pace(of.game)));
  return {
    id: `x${String.fromCharCode(97 + plan.levels.filter((level) => level.extraOf !== null).length)}`,
    game: of.game,
    tier: of.tier,
    version,
    baseExpected: entry.expected,
    expected,
    difficulty: puzzleDifficulty(expected),
    puzzle: entry.puzzle,
    inputs: [],
    output: null,
    fragment: null,
    letter: null,
    minimum: of.minimum === null ? null : entry.minimum,
    gate: null,
    consume: null,
    depth: 0,
    extraOf: of.id,
  };
};
