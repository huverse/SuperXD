import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/puzzle/cipher/cipher_rules.dart';
import 'package:superxd/playground/puzzle/ice/ice_rules.dart';
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

  // [人工决策-2026-11-15 19:18:31]（见 challenge_rules.dart）：挑战按「游戏@题面写法版本」下发，题面写法一改，没更新的应用就看不懂服务器给的题，
  // 所以每个游戏的版本号跟着写法走：这里钉住每个游戏当前版本的一道样例（取自判定向量），写法变了解不开或编回去不一样，就要把 puzzleVersion 加一、换上新写法的样例、重出题库。
  test('题面写法版本：每个能进挑战的游戏从 1 起，样例题面这个版本解得开、编回去一字不差；报给服务器的是「游戏@版本」', () {
    expect(_samples.keys.toSet(), challengeRules.keys.toSet());
    for (final MapEntry(key: game, value: (version, sample)) in _samples.entries) {
      final rules = challengeRules[game]!;
      expect(rules.puzzleVersion, version, reason: game);
      expect(jsonEncode(rules.encodePuzzle(rules.decodePuzzle(sample))), jsonEncode(sample), reason: '$game 的题面写法变了：把 puzzleVersion 加一、换上新写法的样例，再重出题库');
    }
    expect(challengeGameTokens(['hanoi', 'schulte', 'pour', 'twentyfour']), {'hanoi@1', 'twentyfour@1'});
    final vectors = jsonDecode(File(challengeVectorsPath).readAsStringSync()) as Map<String, Object?>;
    expect(vectors['puzzleVersions'], {for (final MapEntry(key: game, value: rules) in challengeRules.entries) game: rules.puzzleVersion}, reason: '服务端按向量里的版本核对它认得的写法');
  });

  group('题库工具', () {
    test('种子由保密串推出、逐位钉住（换了推法线上题库就全变）', () {
      expect(challengeBankSeed('local-test-seed-0001', 'hanoi', PuzzleTier.entry, 0), challengeBankSeed('local-test-seed-0001', 'hanoi', PuzzleTier.entry, 0));
      expect(challengeBankSeed('local-test-seed-0001', 'hanoi', PuzzleTier.entry, 0), isNot(challengeBankSeed('local-test-seed-0002', 'hanoi', PuzzleTier.entry, 0)));
      // 钉住的值另用 Python 按 sha256 前 4 字节算出。
      expect(challengeBankSeed('abcdefghijklmnop', 'ice', PuzzleTier.hard, 7), 0x57accfd3);
    });

    test('题库按「游戏@题面写法版本.档位」分文件，文件里写着题面写法版本', () {
      expect(challengeBankName('hanoi', PuzzleTier.entry), 'hanoi@1.entry.json');
      expect(challengeBankName('loop', PuzzleTier.expert), 'loop@1.expert.json');
      final file = challengeBankFile('local-test-seed-0001', 'hanoi', PuzzleTier.entry, 2);
      expect(file['version'], challengeBankVersion);
      expect(file['puzzleVersion'], 1);
      expect(file['entries'], isNotEmpty);
    });

    test('每道题能解码、难度分在 1–10、编号不重复、同一题面只留一道；带预计用时与碎片，高档要最少步数的带最少步数', () {
      for (final game in ['hanoi', 'ice', 'cipher', 'knights', 'balance']) {
        final entries = challengeBankEntries('local-test-seed-0001', game, PuzzleTier.hard, 5);
        expect(entries.map((entry) => entry['id']).toSet(), hasLength(entries.length));
        expect(entries.map((entry) => jsonEncode(entry['puzzle'])).toSet(), hasLength(entries.length));
        for (final entry in entries) {
          final puzzle = challengeRules[game]!.decodePuzzle(jsonDecode(jsonEncode(entry['puzzle'])));
          expect(entry['difficulty'], inInclusiveRange(1, 10));
          expect(entry['expected'], challengeRules[game]!.expectedSeconds(puzzle));
          expect(entry['minimum'], game == 'hanoi' || game == 'ice' ? isA<int>() : isNull);
          expect(entry['fragment'], isA<int>());
          expect(entry.containsKey('exits'), game == 'ice');
        }
      }
    });

    test('收碎片的游戏：记下的每一处写成 ? 都做不出来，值对得上题面；冰面的出口里有原终点、每个出口带自己的最少步数（同终点的一样，步数上限因此对哪个出口都对）', () {
      for (final entry in challengeBankEntries('local-test-seed-0001', 'queens', PuzzleTier.normal, 3)) {
        final puzzle = const QueensRules().decodePuzzle(entry['puzzle']);
        for (final slot in (entry['slots']! as List).cast<Map<String, int>>()) {
          expect(puzzle.given[slot['at']!], slot['value']);
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
      for (final entry in challengeBankEntries('local-test-seed-0001', 'cipher', PuzzleTier.normal, 3)) {
        final puzzle = const CipherRules().decodePuzzle(entry['puzzle']);
        for (final slot in (entry['slots']! as List).cast<Map<String, int>>()) {
          expect(puzzle.rows[slot['at']!].exact, slot['value']);
        }
      }
      final cards = challengeBankEntries('local-test-seed-0001', 'twentyfour', PuzzleTier.entry, 1).single;
      expect([for (final slot in (cards['slots']! as List).cast<Map<String, int>>()) slot['value']], (cards['puzzle']! as Map)['numbers']);
      for (final entry in challengeBankEntries('local-test-seed-0001', 'ice', PuzzleTier.normal, 3)) {
        final puzzle = const IceRules().decodePuzzle(entry['puzzle']);
        final exits = (entry['exits']! as List).cast<Map<String, int>>();
        expect(exits.map((exit) => exit['cell']), contains(puzzle.goal));
        for (final exit in exits) {
          final goal = puzzle.copyWith(goal: exit['cell']);
          expect(exit['minimum'], iceMinMoves(goal));
          expect(exit['minimum'], entry['minimum']);
          expect(exit['fragment'], exit['minimum']);
        }
      }
    });
  });
}

// 每个能进挑战的游戏当前题面写法版本的一道样例（取自判定向量的入门档），键的顺序同 encodePuzzle。
const _samples = <String, (int, Object)>{
  'hanoi': (1, {'disks': 3, 'start': [0, 0, 0], 'target': 2}),
  'ice': (2, {'width': 6, 'height': 6, 'tiles': '000110001000000000010010100000001000', 'gems': [], 'start': 17, 'goal': 9, 'limit': 7}),
  'lights': (1, {'side': 3, 'lights': '011101100'}),
  'boxes': (1, {'width': 7, 'height': 7, 'walls': '1111111100000110011011101001100001110000111111111', 'goals': [12], 'boxes': [31], 'player': 29}),
  'queens': (1, {'size': 5, 'given': [-1, -1, 3, 1, -1]}),
  'river': (1, {'variant': 'farmer', 'capacity': 2, 'people': [0, 2, 3, 1]}),
  'nonogram': (1, {'width': 5, 'height': 5, 'rows': [[2, 2], [5], [1, 1], [1], [3]], 'columns': [[3], [2, 1], [1, 2], [2, 1], [3]]}),
  'knights': (1, {'claims': [[1, 1], [3, 0]]}),
  'logicgrid': (1, {'people': 3, 'categories': [[2, [1, 3, 4]], [5, [1, 2, 5]]], 'clues': [[0, 0, 1, 1, 0], [1, 0, 0, 1, 1], [1, 1, 1, 2, 2], [0, 1, 0, 2, 1]]}),
  'cipher': (1, {'length': 3, 'digits': 6, 'rows': [[[3, 0, 2], 2, 0], [[4, 3, 5], 0, 0]]}),
  'twentyfour': (1, {'numbers': [1, 6, 9, 9], 'ops': [0, 1, 2, 3]}),
  'mines': (1, {'width': 6, 'height': 6, 'mines': '000010101010100000000000000000000000', 'start': 25}),
  'flash': (1, {'side': 3, 'show': 1500, 'rounds': [[[2, 4, 5], [1, 5, 8], [0, 6, 8], [0, 4, 7], [1, 4, 8], [2, 5, 7]], [[0, 3, 8], [1, 3, 8], [3, 6, 8], [0, 6, 7], [2, 3, 5], [3, 5, 7]], [[0, 1, 3], [0, 2, 3], [2, 6, 7], [0, 3, 4], [2, 3, 4], [4, 7, 8]], [[0, 3, 4, 7], [0, 2, 4, 5], [1, 2, 5, 7], [4, 5, 6, 8], [0, 1, 6, 8], [1, 5, 6, 8]], [[3, 5, 6, 7], [2, 4, 5, 7], [1, 4, 5, 6], [0, 2, 4, 7], [1, 2, 4, 5], [1, 2, 3, 5]]]}),
  'loop': (1, {'width': 4, 'height': 4, 'clues': [-1, 2, -1, -1, -1, -1, -1, 1, 3, 0, 3, -1, -1, -1, -1, -1]}),
  'balance': (1, {'balls': 9, 'weighings': 2, 'knownHeavy': true, 'direction': false, 'seed': 3308915240}),
};
