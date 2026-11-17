import { readFileSync } from 'node:fs';

import { clientGames, judge, judgedGames, judgedVersions, withinStepLimit } from 'src/modules/challenge/judges/judges';

// 客户端 tool/challenge_vectors.dart 用 Dart 规则生成的向量（test/challenge_vectors_test.dart 读同一份文件）：同一道题、同一个答案，两端判得一模一样。
// minimum 与 passed 只在要最少步数的显式用例里有（汉诺塔高档放宽到 1.2 倍，人工决策见客户端 challenge_rules.dart 的 11-17 14:17:05 那条）。
type Case = { tier: string; puzzle: unknown; minimum?: number; answers: { answer: unknown; expect: { kind: string; penalties?: number }; passed?: boolean }[] };
const vectors = JSON.parse(readFileSync(new URL('./vectors/challenge_judge_v1.json', import.meta.url), 'utf8')) as { version: number; puzzleVersions: Record<string, number>; games: Record<string, Case[]> };
// 已经换了写法的旧版本（客户端规则里没有了、服务端判定留给旧客户端）：加版本前用 tool/challenge_vectors.dart --freeze <游戏> 把那时的向量搬来，键是「游戏@版本」。
const frozen = JSON.parse(readFileSync(new URL('./vectors/challenge_judge_frozen.json', import.meta.url), 'utf8')) as { version: number; games: Record<string, Case[]> };

describe('challenge judge vectors', () => {
  it('向量覆盖全部能进挑战的游戏', () => {
    expect(new Set(Object.keys(vectors.games))).toEqual(judgedGames);
  });

  // 人工决策见客户端 challenge_rules.dart 的 11-15 19:18 那条：题面带写法版本，服务器只排、只下发认得的版本。
  it('向量里每个游戏的题面写法版本，这份判定都认得', () => {
    expect(new Set(Object.keys(vectors.puzzleVersions))).toEqual(judgedGames);
    for (const [game, version] of Object.entries(vectors.puzzleVersions)) expect(judgedVersions.get(game)?.has(version), game).toBe(true);
    expect(() => judge('hanoi', vectors.games.hanoi[0].puzzle, [], 99)).toThrow(/hanoi@99/);
  });

  it('客户端报的「游戏@版本」：只报游戏名的旧客户端按第 1 版；这份判定不认得的游戏或版本不算', () => {
    expect(clientGames(['hanoi', 'ice@1', 'loop@2', 'schulte@1', 'queens@0', 'cipher@1x'])).toEqual(new Map([['hanoi', 1], ['ice', 1]]));
  });

  it('冻结的旧版本向量：这份判定都还认得，且不是客户端现在的版本', () => {
    for (const token of Object.keys(frozen.games)) {
      const [game, version] = token.split('@');
      expect(judgedVersions.get(game)?.has(Number(version)), token).toBe(true);
      expect(vectors.puzzleVersions[game], token).not.toBe(Number(version));
    }
  });

  for (const [token, cases] of Object.entries(frozen.games)) {
    it(`${token}（旧版本）判定同当时的 Dart`, () => {
      const [game, version] = token.split('@');
      for (const [index, item] of cases.entries()) {
        for (const [order, { answer, expect: expected }] of item.answers.entries()) {
          const verdict = judge(game, item.puzzle, answer, Number(version));
          expect(verdict.kind === 'solved' ? { kind: verdict.kind, penalties: verdict.penalties } : verdict, `${token} ${item.tier} 第 ${index} 题第 ${order} 个答案`).toEqual(expected);
        }
      }
    });
  }

  for (const [game, cases] of Object.entries(vectors.games)) {
    it(`${game} 判定同 Dart`, () => {
      for (const [index, item] of cases.entries()) {
        for (const [order, { answer, expect: expected }] of item.answers.entries()) {
          // 只比两端共用的口径（kind 与失误数）；步数与按答案给的碎片另在 challenge_rules 里测。
          const verdict = judge(game, item.puzzle, answer, vectors.puzzleVersions[game]);
          expect(verdict.kind === 'solved' ? { kind: verdict.kind, penalties: verdict.penalties } : verdict, `${game} ${item.tier} 第 ${index} 题第 ${order} 个答案`).toEqual(expected);
          if (item.minimum !== undefined) {
            const passed = verdict.kind === 'solved' && withinStepLimit(game, vectors.puzzleVersions[game], item.minimum, verdict.steps!);
            expect(passed, `${game} 最少 ${item.minimum} 步第 ${order} 个答案`).toBe(item.answers[order].passed);
          }
        }
      }
    });
  }
});
