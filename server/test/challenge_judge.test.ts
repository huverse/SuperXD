import { readFileSync } from 'node:fs';

import { judge, judgedGames } from 'src/modules/challenge/judges/judges';

// 客户端 tool/challenge_vectors.dart 用 Dart 规则生成的向量（test/challenge_vectors_test.dart 读同一份文件）：同一道题、同一个答案，两端判得一模一样。
type Case = { tier: string; puzzle: unknown; answers: { answer: unknown; expect: { kind: string; penalties?: number } }[] };
const vectors = JSON.parse(readFileSync(new URL('./vectors/challenge_judge_v1.json', import.meta.url), 'utf8')) as { version: number; games: Record<string, Case[]> };

describe('challenge judge vectors', () => {
  it('向量覆盖全部能进挑战的游戏', () => {
    expect(new Set(Object.keys(vectors.games))).toEqual(judgedGames);
  });

  for (const [game, cases] of Object.entries(vectors.games)) {
    it(`${game} 判定同 Dart`, () => {
      for (const [index, item] of cases.entries()) {
        for (const [order, { answer, expect: expected }] of item.answers.entries()) {
          expect(judge(game, item.puzzle, answer), `${game} ${item.tier} 第 ${index} 题第 ${order} 个答案`).toEqual(expected);
        }
      }
    });
  }
});
