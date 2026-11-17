import { balanceJudge, flashJudge, loopJudge, minesJudge, twentyFourJudge } from 'src/modules/challenge/judges/board_judges';
import { cipherJudge, logicGridJudge } from 'src/modules/challenge/judges/deduction_judges';
import { Judge, JudgeFormatError } from 'src/modules/challenge/judges/judge_input';
import { knightsJudge, nonogramJudge, riverJudge } from 'src/modules/challenge/judges/logic_judges';
import { boxesJudge, hanoiJudge, iceJudge, iceJudgeV2, lightsJudge, queensJudge } from 'src/modules/challenge/judges/moves_judges';

// 能进挑战的游戏（同客户端 playground_catalog.dart 里 challengeable 为真的，id 发出后不改），按题面写法版本登记判定
// （同客户端规则的 puzzleVersion，人工决策见客户端 lib/playground/challenge/challenge_rules.dart 的 11-15 19:18 那条）。舒尔特方格（拼手速）与画线入杯（物理模拟）不在这里。
// 客户端改了某个游戏的题面写法（版本加一）时，这里加上新版本的判定、旧版本的留到不再有客户端报它；旧版本的测试向量冻结在
// test/vectors/challenge_judge_frozen.json（tool/challenge_vectors.dart --freeze <游戏> 在加版本前搬过去）。
const judges = {
  hanoi: { 1: hanoiJudge },
  ice: { 1: iceJudge, 2: iceJudgeV2 },
  lights: { 1: lightsJudge },
  boxes: { 1: boxesJudge },
  queens: { 1: queensJudge },
  river: { 1: riverJudge },
  nonogram: { 1: nonogramJudge },
  knights: { 1: knightsJudge },
  logicgrid: { 1: logicGridJudge },
  cipher: { 1: cipherJudge },
  twentyfour: { 1: twentyFourJudge },
  mines: { 1: minesJudge },
  flash: { 1: flashJudge },
  loop: { 1: loopJudge },
  balance: { 1: balanceJudge },
} as unknown as Record<string, Record<number, Judge<unknown, unknown>>>;

export const judgedGames = new Set(Object.keys(judges));

// 每个游戏这份判定认得的题面写法版本。
export const judgedVersions: ReadonlyMap<string, ReadonlySet<number>> = new Map(Object.entries(judges).map(([game, versions]) => [game, new Set(Object.keys(versions).map(Number))]));

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
  const rules = judges[game]?.[version];
  if (rules === undefined) throw new Error(`没有 ${game}@${version} 的判定`);
  const puzzle = rules.decodePuzzle(puzzleJson);
  let answer: unknown;
  try {
    answer = rules.decodeAnswer(answerJson);
  } catch (error) {
    if (error instanceof JudgeFormatError) return { kind: 'invalid' };
    throw error;
  }
  if (!rules.solved(puzzle, answer)) return { kind: 'unsolved' };
  return { kind: 'solved', penalties: rules.penalties?.(puzzle, answer) ?? 0, steps: rules.steps?.(puzzle, answer) ?? null };
};
