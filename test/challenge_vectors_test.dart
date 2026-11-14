import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/puzzle/loop/loop_rules.dart';
import 'package:superxd/playground/puzzle/queens/queens_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';

import '../tool/challenge_bank.dart';
import '../tool/challenge_vectors.dart';

// 挑战判定的双端向量（人工决策见 lib/playground/challenge/challenge_rules.dart）：仓库里的 server/test/vectors/challenge_judge_v1.json
// 要与现在的 Dart 规则一字不差（规则改了口径就重跑 tool/challenge_vectors.dart，服务端 test/challenge_judge.test.ts 读同一份文件）。
void main() {
  test('能进挑战的游戏就是注册表里 challengeable 为真的那些', () {
    expect(challengeRules.keys.toSet(), {for (final game in playgroundCatalog) if (game.challengeable) game.id});
    expect(challengeConsumers.every(challengeRules.containsKey), isTrue);
  });

  test('仓库里的判定向量就是现在的规则生成的（每一条的判定都对得上）', () {
    final file = jsonDecode(File(challengeVectorsPath).readAsStringSync()) as Map<String, Object?>;
    expect(jsonEncode(file), jsonEncode(buildChallengeVectors()), reason: '规则变了：重跑 dart run tool/challenge_vectors.dart，再跑服务端 npm test');
    final games = file['games']! as Map<String, Object?>;
    for (final MapEntry(key: game, value: cases) in games.entries) {
      for (final item in (cases! as List).cast<Map<String, Object?>>()) {
        for (final answer in (item['answers']! as List).cast<Map<String, Object?>>()) {
          expect(challengeVerdict(game, item['puzzle'], answer['answer']), answer['expect'], reason: '$game ${item['tier']}');
        }
      }
    }
  });

  group('题库工具', () {
    test('种子由保密串推出、逐位钉住（换了推法线上题库就全变）', () {
      expect(challengeBankSeed('local-test-seed-0001', 'hanoi', PuzzleTier.entry, 0), challengeBankSeed('local-test-seed-0001', 'hanoi', PuzzleTier.entry, 0));
      expect(challengeBankSeed('local-test-seed-0001', 'hanoi', PuzzleTier.entry, 0), isNot(challengeBankSeed('local-test-seed-0002', 'hanoi', PuzzleTier.entry, 0)));
      // 钉住的值另用 Python 按 sha256 前 4 字节算出。
      expect(challengeBankSeed('abcdefghijklmnop', 'ice', PuzzleTier.hard, 7), 0x57accfd3);
    });

    test('每道题能解码、难度分在 1–10、编号不重复、同一题面只留一道', () {
      for (final game in ['hanoi', 'ice', 'cipher', 'knights']) {
        final entries = challengeBankEntries('local-test-seed-0001', game, PuzzleTier.normal, 5);
        expect(entries.map((entry) => entry['id']).toSet(), hasLength(entries.length));
        expect(entries.map((entry) => jsonEncode(entry['puzzle'])).toSet(), hasLength(entries.length));
        for (final entry in entries) {
          challengeRules[game]!.decodePuzzle(jsonDecode(jsonEncode(entry['puzzle'])));
          expect(entry['difficulty'], inInclusiveRange(1, 10));
          expect(entry['slots'], isEmpty);
        }
      }
    });

    test('收钥匙的游戏：记下的每一处挖掉都让题不唯一，值与钥匙数对得上题面', () {
      for (final entry in challengeBankEntries('local-test-seed-0001', 'queens', PuzzleTier.normal, 3)) {
        final puzzle = const QueensRules().decodePuzzle(entry['puzzle']);
        for (final slot in (entry['slots']! as List).cast<Map<String, int>>()) {
          expect(puzzle.given[slot['at']!], slot['value']);
          expect(slot['key'], slot['value']! + 1);
          expect(queensSolve(QueensPuzzle(size: puzzle.size, given: [...puzzle.given]..[slot['at']!] = -1)).count, 2);
        }
      }
      for (final entry in challengeBankEntries('local-test-seed-0001', 'loop', PuzzleTier.easy, 2)) {
        final puzzle = const LoopRules().decodePuzzle(entry['puzzle']);
        final slots = (entry['slots']! as List).cast<Map<String, int>>();
        expect(slots, isNotEmpty);
        for (final slot in slots) {
          expect(puzzle.clues[slot['at']!], slot['value']);
          expect(loopSolve(LoopPuzzle(width: puzzle.width, height: puzzle.height, clues: [...puzzle.clues]..[slot['at']!] = -1)).count, 2);
        }
      }
      final cards = challengeBankEntries('local-test-seed-0001', 'twentyfour', PuzzleTier.entry, 1).single;
      expect([for (final slot in (cards['slots']! as List).cast<Map<String, int>>()) slot['value']], (cards['puzzle']! as Map)['numbers']);
    });
  });
}
