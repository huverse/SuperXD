import { readFileSync } from 'node:fs';

import { clientGames, judge, judgedGames, judgedVersions } from 'src/modules/challenge/judges/judges';

// 客户端 tool/challenge_vectors.dart 用 Dart 规则生成的向量（test/challenge_vectors_test.dart 读同一份文件）：同一道题、同一个答案，两端判得一模一样。
type Case = { tier: string; puzzle: unknown; answers: { answer: unknown; expect: { kind: string; penalties?: number } }[] };
const vectors = JSON.parse(readFileSync(new URL('./vectors/challenge_judge_v1.json', import.meta.url), 'utf8')) as { version: number; puzzleVersions: Record<string, number>; games: Record<string, Case[]> };

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

  for (const [game, cases] of Object.entries(vectors.games)) {
    it(`${game} 判定同 Dart`, () => {
      for (const [index, item] of cases.entries()) {
        for (const [order, { answer, expect: expected }] of item.answers.entries()) {
          // 只比两端共用的口径（kind 与失误数）；步数与按答案给的碎片另在 challenge_rules 里测。
          const verdict = judge(game, item.puzzle, answer, vectors.puzzleVersions[game]);
          expect(verdict.kind === 'solved' ? { kind: verdict.kind, penalties: verdict.penalties } : verdict, `${game} ${item.tier} 第 ${index} 题第 ${order} 个答案`).toEqual(expected);
        }
      }
    });
  }
});
