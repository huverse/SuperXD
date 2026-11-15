import { balanceJudge, flashJudge, flashMistakes, loopJudge, minesJudge, twentyFourJudge } from 'src/modules/challenge/judges/board_judges';
import { cipherJudge, logicGridJudge } from 'src/modules/challenge/judges/deduction_judges';
import { Judge, JudgeFormatError } from 'src/modules/challenge/judges/judge_input';
import { knightsJudge, nonogramJudge, riverJudge } from 'src/modules/challenge/judges/logic_judges';
import { boxesJudge, boxesPushes, BoxesPuzzle, hanoiJudge, iceJudge, lightsJudge, queensJudge } from 'src/modules/challenge/judges/moves_judges';

// 能进挑战的游戏（同客户端 playground_catalog.dart 里 challengeable 为真的，id 发出后不改）。舒尔特方格（拼手速）与画线入杯（物理模拟）不在这里。
const judges = {
  hanoi: hanoiJudge,
  ice: iceJudge,
  lights: lightsJudge,
  boxes: boxesJudge,
  queens: queensJudge,
  river: riverJudge,
  nonogram: nonogramJudge,
  knights: knightsJudge,
  logicgrid: logicGridJudge,
  cipher: cipherJudge,
  twentyfour: twentyFourJudge,
  mines: minesJudge,
  flash: flashJudge,
  loop: loopJudge,
  balance: balanceJudge,
} as Record<string, Judge<unknown, unknown>>;

export const judgedGames = new Set(Object.keys(judges));

// 每个游戏这份判定认得的题面写法版本（同客户端规则的 puzzleVersion，人工决策见客户端 lib/playground/challenge/challenge_rules.dart 的 11-15 19:18 那条）：
// 客户端改了某个游戏的题面写法（版本加一）时，这里移植新写法的判定并把版本加进来；旧版本留到不再有客户端报它。
export const judgedVersions: ReadonlyMap<string, ReadonlySet<number>> = new Map(Object.keys(judges).map((game) => [game, new Set([1])]));

// 客户端报的玩得了的游戏（「hanoi@1」；只报游戏名的旧客户端按第 1 版）里这份判定认得的：游戏 → 题面写法版本。认不得的游戏或版本不算。
const clientToken = /^([a-z][a-z0-9_]{0,23})(?:@([1-9][0-9]{0,3}))?$/;
export const clientGames = (tokens: string[]): Map<string, number> => {
  const games = new Map<string, number>();
  for (const token of tokens) {
    const match = clientToken.exec(token);
    if (match === null) continue;
    const version = match[2] === undefined ? 1 : Number(match[2]);
    if (judgedVersions.get(match[1])?.has(version) === true) games.set(match[1], version);
  }
  return games;
};

export type Verdict = { kind: 'solved'; penalties: number; steps: number | null } | { kind: 'unsolved' } | { kind: 'invalid' };

// 判一次作答：答案不合法是 invalid（同 Dart 的 decodeAnswer 抛错），合法但没解开是 unsolved。
// penalties 是答案里自带的失误（记忆闪光一题内点错的次数），计分时同错交一样扣；steps 是要最少步数的游戏用了几步（推箱子按推的次数）。
// 题面坏了（题库写坏）照常抛错，由调用方当服务端错误。version 是这一关题面的写法版本（11-15 以前排的局没记，按第 1 版）。
export const judge = (game: string, puzzleJson: unknown, answerJson: unknown, version = 1): Verdict => {
  const rules = judges[game];
  if (rules === undefined || judgedVersions.get(game)?.has(version) !== true) throw new Error(`没有 ${game}@${version} 的判定`);
  const puzzle = rules.decodePuzzle(puzzleJson);
  let answer: unknown;
  try {
    answer = rules.decodeAnswer(answerJson);
  } catch (error) {
    if (error instanceof JudgeFormatError) return { kind: 'invalid' };
    throw error;
  }
  if (!rules.solved(puzzle, answer)) return { kind: 'unsolved' };
  const penalties = game === 'flash' ? flashMistakes(puzzle as Parameters<typeof flashMistakes>[0], answer as number[][])! : 0;
  const steps = game === 'boxes' ? boxesPushes(puzzle as BoxesPuzzle, answer as number[]) : ['hanoi', 'ice', 'lights'].includes(game) ? (answer as unknown[]).length : null;
  return { kind: 'solved', penalties, steps };
};
