import { balanceJudge, flashJudge, flashMistakes, loopJudge, minesJudge, twentyFourJudge } from 'src/modules/challenge/judges/board_judges';
import { cipherJudge, logicGridJudge } from 'src/modules/challenge/judges/deduction_judges';
import { Judge, JudgeFormatError } from 'src/modules/challenge/judges/judge_input';
import { knightsJudge, nonogramJudge, riverJudge } from 'src/modules/challenge/judges/logic_judges';
import { boxesJudge, hanoiJudge, iceJudge, lightsJudge, queensJudge } from 'src/modules/challenge/judges/moves_judges';

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

export type Verdict = { kind: 'solved'; penalties: number } | { kind: 'unsolved' } | { kind: 'invalid' };

// 判一次作答：答案不合法是 invalid（同 Dart 的 decodeAnswer 抛错），合法但没解开是 unsolved。
// penalties 是答案里自带的失误（记忆闪光一题内点错的次数），计分时同错交一样扣。题面坏了（题库写坏）照常抛错，由调用方当服务端错误。
export const judge = (game: string, puzzleJson: unknown, answerJson: unknown): Verdict => {
  const rules = judges[game];
  if (rules === undefined) throw new Error(`没有 ${game} 的判定`);
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
  return { kind: 'solved', penalties };
};
