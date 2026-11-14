import { randomInt } from 'node:crypto';

import { ChallengeScoring, ChallengeTemplate, ChallengeTier, consumerGames } from 'src/modules/challenge/challenge_config';
import { BankEntry } from 'src/modules/challenge/challenge_content';

// 一局开始时排好的计划（人工决策见客户端 lib/playground/challenge/challenge_rules.dart 的钥匙填空）：每关是哪个游戏、哪道题；
// 收钥匙的关挖掉哪几处条件、各由哪一关的钥匙补上；给钥匙的关的钥匙数。计划连同题面整份存进这一局（题库热更新换了文件也不影响进行中的局）。

// 收钥匙的关里挖掉的一处：from 是给这把钥匙的关，at 是位置，value 是题面里的真值，key 是给玩家看的钥匙数。
export type PlanSlot = { from: string; at: number; value: number; key: number };

export type PlanLevel = {
  id: string;
  game: string;
  tier: ChallengeTier;
  difficulty: number;
  puzzle: unknown;
  // 收哪几关的钥匙（边的顺序），没有为空。
  inputs: string[];
  // 钥匙给哪一关，没有（最后一关）为 null。
  output: string | null;
  // 这一关解开后给的钥匙数（output 不为空才有）。
  key: number | null;
  slots: PlanSlot[];
  // 从源头数第几层（串联深度，计分用）。
  depth: number;
};

export type ChallengePlan = { challengeId: string; title: string; label: string; timeLimit: number; endsAt: number; scoring: ChallengeScoring; levels: PlanLevel[] };

export class ChallengePlanError extends Error {}

// 随机源可注入（测试固定）；默认用密码学随机数，玩家猜不到下一局的题。
export type PlanRandom = (bound: number) => number;
const secureRandom: PlanRandom = (bound) => randomInt(bound);

const pick = <T>(items: T[], random: PlanRandom) => items[random(items.length)];

// 按模板排一局：拓扑序（先排给钥匙的关）逐关挑游戏与题。游戏只在客户端玩得了（supported）且题库里有这一档的里挑，尽量不重复；
// 收钥匙的关只挑挖得出足够多处条件的题。挑不出来（配置与题库对不上、客户端太旧）抛 ChallengePlanError。
export const planChallenge = async (
  input: { challengeId: string; title: string; template: ChallengeTemplate; endsAt: number; scoring: ChallengeScoring; supported: Set<string>; allGames: Set<string> },
  bank: (game: string, tier: ChallengeTier) => Promise<BankEntry[]>,
  random: PlanRandom = secureRandom,
): Promise<ChallengePlan> => {
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
  for (const node of [...template.nodes].sort((left, right) => depthOf(left.id) - depthOf(right.id))) {
    const inputs = inputsOf(node.id);
    const pool = (node.games ?? [...(inputs.length > 0 ? consumerGames : input.allGames)]).filter((game) => input.supported.has(game));
    const candidates: { game: string; entries: BankEntry[] }[] = [];
    for (const game of pool) {
      const entries = (await bank(game, node.tier)).filter((entry) => entry.slots.length >= inputs.length);
      if (entries.length > 0) candidates.push({ game, entries });
    }
    if (candidates.length === 0) throw new ChallengePlanError(`${template.id} 的 ${node.id} 挑不出题`);
    const fresh = candidates.filter((candidate) => !used.has(candidate.game));
    const chosen = pick(fresh.length > 0 ? fresh : candidates, random);
    used.add(chosen.game);
    const entry = pick(chosen.entries, random);
    // 挖哪几处：从能挖的里不放回地随机挑，按边的顺序分给各个给钥匙的关。
    const open = [...entry.slots];
    const slots = inputs.map((from) => {
      const slot = open.splice(random(open.length), 1)[0];
      return { from, at: slot.at, value: slot.value, key: slot.key };
    });
    levels.set(node.id, { id: node.id, game: chosen.game, tier: node.tier, difficulty: entry.difficulty, puzzle: entry.puzzle, inputs, output: outputOf(node.id), key: null, slots, depth: depthOf(node.id) });
  }
  for (const level of levels.values()) {
    if (level.output !== null) level.key = levels.get(level.output)!.slots.find((slot) => slot.from === level.id)!.key;
  }
  return {
    challengeId: input.challengeId,
    title: input.title,
    label: template.label,
    timeLimit: template.timeLimit,
    endsAt: input.endsAt,
    scoring: input.scoring,
    levels: template.nodes.map((node) => levels.get(node.id)!),
  };
};

// 收钥匙的关解锁前给玩家看的预告：挖掉的地方写「?」，看得出要靠前面哪几关。题面结构见各游戏的 Dart 规则。
export const teaserOf = (level: PlanLevel) => {
  if (level.slots.length === 0) return null;
  const puzzle = level.puzzle as Record<string, unknown>;
  const hidden = new Set(level.slots.map((slot) => slot.at));
  switch (level.game) {
    case 'twentyfour':
      return `四张牌：${(puzzle.numbers as number[]).map((number, index) => (hidden.has(index) ? '?' : String(number))).join(' ')}`;
    case 'queens':
      return `${String(puzzle.size)}×${String(puzzle.size)}，${level.slots.map((slot) => `第 ${slot.at + 1} 行的锁定皇后在第 ? 列`).join('，')}`;
    case 'loop': {
      const width = puzzle.width as number;
      return `${width}×${String(puzzle.height)}，${level.slots.map((slot) => `第 ${Math.trunc(slot.at / width) + 1} 行第 ${(slot.at % width) + 1} 格是 ?`).join('，')}`;
    }
    default:
      return null;
  }
};
