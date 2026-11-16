import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/puzzle/flash/flash_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';

const _rules = FlashRules();

// 每档的题型、边长、5 轮各几格、时长、难易分与预计用时（同 flash_rules.dart 的 _tiers 与 complexity、expectedSeconds 的注释）。
const _tiers = {
  PuzzleTier.entry: (variant: FlashVariant.spot, side: 4, counts: [3, 3, 4, 4, 5], show: 1500, gap: 0, score: 2, seconds: 45),
  PuzzleTier.easy: (variant: FlashVariant.spot, side: 5, counts: [5, 5, 6, 7, 8], show: 1600, gap: 0, score: 3, seconds: 70),
  PuzzleTier.normal: (variant: FlashVariant.sequence, side: 5, counts: [4, 4, 5, 6, 7], show: 700, gap: 250, score: 5, seconds: 112),
  PuzzleTier.hard: (variant: FlashVariant.reverse, side: 6, counts: [4, 4, 5, 6, 7], show: 700, gap: 250, score: 7, seconds: 161),
  PuzzleTier.expert: (variant: FlashVariant.numbers, side: 6, counts: [6, 7, 8, 9, 10], show: 300, gap: 0, score: 9, seconds: 231),
};

// 不在这一组里的第一格。
int _outside(FlashPuzzle puzzle, List<int> pattern) => List.generate(puzzle.side * puzzle.side, (cell) => cell).firstWhere((cell) => !pattern.contains(cell));

// 第 round 轮第 attempt 次：先点对 hits 格再点错一下（数字顺序点块外的格不响应，点错是跳过下一个数先点了后面的块）。
List<int> _miss(FlashPuzzle puzzle, int round, int attempt, {int hits = 0}) {
  final pattern = flashPattern(puzzle, round, attempt);
  return [...pattern.take(hits), puzzle.variant == FlashVariant.numbers ? pattern[hits + 1] : _outside(puzzle, pattern)];
}

void main() {
  group('记忆闪光规则', () {
    test('每档出题：题型与参数对得上，每组在棋盘内、没有重格、不占满一条线（位置记忆升序），整道题的格不重样；参考解一次没错地解开；可复现', () {
      for (final MapEntry(key: tier, value: expected) in _tiers.entries) {
        for (var seed = 0; seed < 30; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          final reason = '$tier $seed';
          expect(puzzle.variant, expected.variant, reason: reason);
          expect(puzzle.side, expected.side, reason: reason);
          expect(puzzle.showMillis, expected.show, reason: reason);
          expect(puzzle.gapMillis, expected.gap, reason: reason);
          expect(puzzle.mirror, isFalse);
          expect(puzzle.rounds, hasLength(flashRounds), reason: reason);
          final seen = <String>{};
          for (final (round, patterns) in puzzle.rounds.indexed) {
            expect(patterns, hasLength(flashPatternsPerRound), reason: reason);
            for (final pattern in patterns) {
              expect(pattern, hasLength(expected.counts[round]), reason: '$reason 第 $round 轮');
              expect(pattern, everyElement(inInclusiveRange(0, puzzle.side * puzzle.side - 1)), reason: reason);
              expect(pattern.toSet(), hasLength(pattern.length), reason: '$reason $pattern');
              final sorted = [...pattern]..sort();
              if (!puzzle.variant.ordered) expect(pattern, sorted, reason: '$reason $pattern');
              expect(flashHasLine(puzzle.side, pattern.toSet()), isFalse, reason: '$reason $pattern');
              expect(seen.add(sorted.join(',')), isTrue, reason: '$reason 重样 $pattern');
            }
          }
          expect(draw.solution, [for (var round = 0; round < flashRounds; round++) flashPattern(puzzle, round, 0)], reason: reason);
          expect(flashMistakes(puzzle, draw.solution), 0, reason: reason);
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: reason);
        }
      }
      String encoded(int seed, PuzzleTier tier) => jsonEncode(_rules.encodePuzzle(_rules.generate(seed, tier).puzzle));
      expect(encoded(7, PuzzleTier.hard), encoded(7, PuzzleTier.hard));
      expect(encoded(7, PuzzleTier.expert), isNot(encoded(8, PuzzleTier.expert)));
      // 按先后点的组不是升序存的（先后是洗出来的）。
      final sequence = _rules.generate(1, PuzzleTier.normal).puzzle;
      expect(sequence.rounds.expand((patterns) => patterns).any((pattern) => jsonEncode(pattern) != jsonEncode([...pattern]..sort())), isTrue);
    });

    test('出题快：五档各 60 道一共不到 1 秒', () {
      final watch = Stopwatch()..start();
      for (final tier in PuzzleTier.values) {
        for (var seed = 100; seed < 160; seed++) {
          _rules.generate(seed, tier);
        }
      }
      expect(watch.elapsedMilliseconds, lessThan(1000));
    });

    test('整行、整列、两条对角线全占才算成线', () {
      expect(flashHasLine(3, {0, 1, 2}), isTrue);
      expect(flashHasLine(3, {1, 4, 7}), isTrue);
      expect(flashHasLine(3, {0, 4, 8}), isTrue);
      expect(flashHasLine(3, {2, 4, 6}), isTrue);
      expect(flashHasLine(3, {0, 1, 5}), isFalse);
      expect(flashHasLine(4, {0, 1, 2, 7}), isFalse);
      expect(flashHasLine(4, {3, 6, 9, 12, 0}), isTrue);
    });

    test('要点的格：倒序反过来，镜像每格换成左右镜像、先后不变（位置记忆重排成升序）；亮的时长按题型算', () {
      FlashPuzzle puzzle(FlashVariant variant, List<int> cells) => FlashPuzzle(side: 4, variant: variant, showMillis: 700, gapMillis: 250, rounds: [[cells]]);
      expect(flashPattern(puzzle(FlashVariant.spot, [1, 6, 8]), 0, 0), [1, 6, 8]);
      expect(flashPattern(puzzle(FlashVariant.spot, [1, 6, 8]).mirrored, 0, 0), [2, 5, 11]);
      expect(flashPattern(puzzle(FlashVariant.sequence, [8, 1, 6]), 0, 0), [8, 1, 6]);
      expect(flashPattern(puzzle(FlashVariant.sequence, [8, 1, 6]).mirrored, 0, 0), [11, 2, 5]);
      expect(flashPattern(puzzle(FlashVariant.reverse, [8, 1, 6]), 0, 0), [6, 1, 8]);
      expect(flashPattern(puzzle(FlashVariant.reverse, [8, 1, 6]).mirrored, 0, 0), [5, 2, 11]);
      expect(flashPattern(puzzle(FlashVariant.numbers, [8, 1, 6]).mirrored, 0, 0), [11, 2, 5]);
      // 镜像只改要点的，亮的照旧。
      expect(flashShown(puzzle(FlashVariant.reverse, [8, 1, 6]).mirrored, 0, 0), [8, 1, 6]);
      expect(flashMirror(4, 0), 3);
      expect(flashMirror(4, 6), 5);
      expect(flashMirror(5, 12), 12);

      final draws = {for (final tier in PuzzleTier.values) tier: _rules.generate(1, tier).puzzle};
      expect(flashExposure(draws[PuzzleTier.entry]!, 3), 1500);
      expect(flashExposure(draws[PuzzleTier.easy]!, 8), 1600);
      expect(flashExposure(draws[PuzzleTier.normal]!, 4), 4 * 700 + 3 * 250);
      expect(flashExposure(draws[PuzzleTier.hard]!, 7), 7 * 700 + 6 * 250);
      expect(flashExposure(draws[PuzzleTier.expert]!, 6), 1800);
      expect(flashExposure(draws[PuzzleTier.expert]!, 10), 3000);
    });

    test('点一格：已点亮的不响应；位置记忆顺序不限，按先后点的要正好是下一格；数字顺序里块外的格不响应、跳过数字算点错', () {
      expect(flashTap(FlashVariant.spot, [1, 4, 7], [1], 1), FlashTap.ignored);
      expect(flashTap(FlashVariant.spot, [1, 4, 7], [1], 7), FlashTap.hit);
      expect(flashTap(FlashVariant.spot, [1, 4, 7], [1, 7], 4), FlashTap.cleared);
      expect(flashTap(FlashVariant.spot, [1, 4, 7], [1], 2), FlashTap.missed);
      expect(flashTap(FlashVariant.spot, [1, 4, 7], [], 0), FlashTap.missed);

      for (final variant in [FlashVariant.sequence, FlashVariant.reverse]) {
        expect(flashTap(variant, [7, 1, 4], [], 7), FlashTap.hit);
        expect(flashTap(variant, [7, 1, 4], [], 1), FlashTap.missed, reason: '在这组里但不是下一格');
        expect(flashTap(variant, [7, 1, 4], [7], 7), FlashTap.ignored);
        expect(flashTap(variant, [7, 1, 4], [7], 2), FlashTap.missed);
        expect(flashTap(variant, [7, 1, 4], [7, 1], 4), FlashTap.cleared);
      }

      expect(flashTap(FlashVariant.numbers, [7, 1, 4], [], 7), FlashTap.hit);
      expect(flashTap(FlashVariant.numbers, [7, 1, 4], [], 4), FlashTap.missed);
      expect(flashTap(FlashVariant.numbers, [7, 1, 4], [], 2), FlashTap.ignored, reason: '块外的格');
      expect(flashTap(FlashVariant.numbers, [7, 1, 4], [7], 7), FlashTap.ignored);
      expect(flashTap(FlashVariant.numbers, [7, 1, 4], [7, 1], 4), FlashTap.cleared);
    });

    test('按规则判定（位置记忆）：顺序不限；少点、多点、点已点亮的、点棋盘外、空的一次、点错后接着点、点错后没换图案、轮数不够或多出、超长都不算', () {
      final draw = _rules.generate(3, PuzzleTier.entry);
      final puzzle = draw.puzzle, solution = draw.solution;
      final first = solution.first, rest = solution.sublist(1);
      final outside = _outside(puzzle, first);
      expect(_rules.solved(puzzle, [for (final taps in solution) taps.reversed.toList()]), isTrue);
      // 少点：最后一轮差一格。
      expect(_rules.solved(puzzle, [...solution.take(4), solution.last.sublist(1)]), isFalse);
      // 多点：点齐以后又点一格。
      expect(_rules.solved(puzzle, [[...first, outside], ...rest]), isFalse);
      // 点齐后多点的一格也不能当成这一次点错、接着换下一组。
      expect(_rules.solved(puzzle, [[...first, outside], flashPattern(puzzle, 0, 1), ...rest]), isFalse);
      expect(_rules.solved(puzzle, [...solution.take(4), [...solution.last, _outside(puzzle, solution.last)]]), isFalse);
      // 点已点亮的格：页面里不响应，答案里不该有。
      expect(_rules.solved(puzzle, [[first.first, ...first], ...rest]), isFalse);
      // 点棋盘外（4×4 的第 16 格）不算点错，整份答案不合规。
      expect(_rules.solved(puzzle, [[16], first, ...rest]), isFalse);
      expect(_rules.solved(puzzle, [[], ...solution]), isFalse);
      // 点错后接着点：点错必须是这一次的最后一下。
      expect(_rules.solved(puzzle, [[outside, ...first], ...rest]), isFalse);
      expect(_rules.solved(puzzle, [[outside, ...first.take(first.length - 1)], ...rest]), isFalse);
      expect(_rules.solved(puzzle, [[outside, ...first.take(first.length - 1)], flashPattern(puzzle, 0, 1), ...rest]), isFalse);
      // 点错后没换图案、照旧点第一组：第二次要点的是第二组。
      expect(_rules.solved(puzzle, [[outside], first, ...rest]), isFalse);
      expect(_rules.solved(puzzle, [[outside], flashPattern(puzzle, 0, 1), ...rest]), isTrue);
      expect(_rules.solved(puzzle, solution.sublist(0, 4)), isFalse);
      expect(_rules.solved(puzzle, [...solution, first]), isFalse);
      // 长度上限：第一轮点错 n 次再走完，一共 n + 5 次。
      List<List<int>> missing(int times) => [for (var attempt = 0; attempt < times; attempt++) _miss(puzzle, 0, attempt), flashPattern(puzzle, 0, times), ...rest];
      expect(_rules.solved(puzzle, missing(flashMaxAttempts - 5)), isTrue);
      expect(_rules.solved(puzzle, missing(flashMaxAttempts - 4)), isFalse);
    });

    test('按规则判定（按先后点）：顺序与数字顺序照亮的先后、倒序反过来，换了先后不算；数字顺序答案里有块外的格不合规；镜像点镜像的格', () {
      for (final tier in [PuzzleTier.normal, PuzzleTier.hard, PuzzleTier.expert]) {
        final draw = _rules.generate(9, tier);
        final puzzle = draw.puzzle, solution = draw.solution;
        final reason = '$tier';
        expect(_rules.solved(puzzle, solution), isTrue, reason: reason);
        // 格都对、先后反了或换了两格。
        expect(_rules.solved(puzzle, [for (final taps in solution) taps.reversed.toList()]), isFalse, reason: reason);
        final swapped = [...solution.first];
        final head = swapped[0];
        swapped[0] = swapped[1];
        swapped[1] = head;
        expect(_rules.solved(puzzle, [swapped, ...solution.sublist(1)]), isFalse, reason: reason);
        // 先点了第二格算点错，换下一组照先后点齐就过了。
        expect(flashMistakes(puzzle, [[solution.first[1]], flashPattern(puzzle, 0, 1), ...solution.sublist(1)]), 1, reason: reason);
        // 倒序：照亮的先后点不算。
        final shown = [for (var round = 0; round < flashRounds; round++) flashShown(puzzle, round, 0)];
        expect(_rules.solved(puzzle, shown), tier != PuzzleTier.hard, reason: reason);
        // 镜像：照亮的格点不算，点镜像的格（先后不变）才算。
        final mirrored = puzzle.mirrored;
        expect(_rules.solved(mirrored, solution), isFalse, reason: reason);
        expect(_rules.solved(mirrored, [for (var round = 0; round < flashRounds; round++) flashPattern(mirrored, round, 0)]), isTrue, reason: reason);
      }
      final numbers = _rules.generate(9, PuzzleTier.expert);
      final outside = _outside(numbers.puzzle, numbers.solution.first);
      expect(flashMistakes(numbers.puzzle, [[outside], ...numbers.solution]), isNull);
      expect(flashMistakes(numbers.puzzle, [[numbers.solution.first.first, outside], ...numbers.solution.sublist(1)]), isNull);
    });

    test('错的次数从答案里数得出：每次点错换这一轮的下一组，备用用完从第一组轮换', () {
      for (final tier in [PuzzleTier.easy, PuzzleTier.hard, PuzzleTier.expert]) {
        final puzzle = _rules.generate(5, tier).puzzle;
        // 位置记忆顺序不限（倒着点也行），按先后点的只能照先后。
        List<int> clear(int round, int attempt) => puzzle.variant.ordered ? flashPattern(puzzle, round, attempt) : flashPattern(puzzle, round, attempt).reversed.toList();
        expect(flashPattern(puzzle, 4, flashPatternsPerRound), flashPattern(puzzle, 4, 0));
        expect(flashPattern(puzzle, 4, flashPatternsPerRound + 1), flashPattern(puzzle, 4, 1));
        final answer = [
          _miss(puzzle, 0, 0, hits: 2),
          clear(0, 1),
          clear(1, 0),
          _miss(puzzle, 2, 0),
          _miss(puzzle, 2, 1, hits: 1),
          clear(2, 2),
          clear(3, 0),
          for (var attempt = 0; attempt < 7; attempt++) _miss(puzzle, 4, attempt, hits: attempt % 3),
          clear(4, 7),
        ];
        expect(flashMistakes(puzzle, answer), 10, reason: '$tier');
        expect(_rules.solved(puzzle, answer), isTrue);
        expect(_rules.penalties(puzzle, answer), 10);
        // 轮换错一位（第 8 次还点第一组）就不算。
        expect(flashMistakes(puzzle, [...answer.sublist(0, answer.length - 1), clear(4, 0)]), isNull);
        expect(flashMistakes(puzzle, _rules.generate(5, tier).solution), 0);
      }
    });

    test('编解码往返（每档与镜像），坏输入抛 FormatException', () {
      for (final tier in PuzzleTier.values) {
        final draw = _rules.generate(11, tier);
        for (final original in [draw.puzzle, draw.puzzle.mirrored]) {
          final puzzle = _rules.decodePuzzle(jsonDecode(jsonEncode(_rules.encodePuzzle(original))));
          expect(puzzle.variant, original.variant);
          expect(puzzle.side, original.side);
          expect(puzzle.showMillis, original.showMillis);
          expect(puzzle.gapMillis, original.gapMillis);
          expect(puzzle.mirror, original.mirror);
          expect(jsonEncode(_rules.encodePuzzle(puzzle)), jsonEncode(_rules.encodePuzzle(original)));
        }
        final answer = [_miss(draw.puzzle, 0, 0, hits: 2), flashPattern(draw.puzzle, 0, 1), ...draw.solution.sublist(1)];
        final decoded = _rules.decodeAnswer(jsonDecode(jsonEncode(_rules.encodeAnswer(answer))));
        expect(flashMistakes(draw.puzzle, decoded), 1, reason: '$tier');
      }
      expect((_rules.encodePuzzle(_rules.generate(1, PuzzleTier.normal).puzzle) as Map).keys, ['side', 'variant', 'show', 'gap', 'rounds']);
      expect((_rules.encodePuzzle(_rules.generate(1, PuzzleTier.expert).puzzle) as Map).keys, ['side', 'variant', 'show', 'rounds']);

      Map<String, Object?> small({Object? side = 3, Object? variant = 'spot', Object? show = 1500, Object? rounds}) => {
        'side': side,
        'variant': variant,
        'show': show,
        'rounds': rounds ?? [[[0, 1, 5], [2, 3, 7]]],
      };
      Map<String, Object?> stepwise({Object? variant = 'sequence', Object? gap = 250, Object? rounds}) => {
        ...small(variant: variant, show: 700, rounds: rounds ?? [[[5, 1, 0], [7, 2, 3]]]),
        'gap': gap,
      };
      expect(_rules.decodePuzzle(small()).rounds.single, [[0, 1, 5], [2, 3, 7]]);
      expect(_rules.decodePuzzle(stepwise()).rounds.single, [[5, 1, 0], [7, 2, 3]]);
      expect(_rules.decodePuzzle(stepwise(variant: 'reverse', gap: 0)).gapMillis, 0);
      expect(_rules.decodePuzzle(small(variant: 'numbers', show: 300, rounds: [[[4, 0, 8]]])).variant, FlashVariant.numbers);
      for (final bad in <Object?>[
        null,
        'x',
        [3],
        small(side: 2),
        small(side: 7),
        small(side: '3'),
        small(variant: null),
        small(variant: 'order'),
        small(variant: 1),
        {'side': 3, 'show': 1500, 'rounds': [[[0, 1, 5]]]},
        small(show: flashMinShowMillis - 1),
        small(show: flashMaxShowMillis + 1),
        small(show: 1500.5),
        {'side': 3, 'variant': 'spot', 'show': 1500},
        {...small(), 'gap': 250},
        {...small(variant: 'numbers'), 'gap': 0},
        {...small(), 'gap': null},
        {...small(), 'mirror': 'yes'},
        small(variant: 'sequence'),
        stepwise(gap: -1),
        stepwise(gap: flashMaxGapMillis + 1),
        stepwise(gap: '250'),
        stepwise(rounds: [[[5, 1, 5]]]),
        stepwise(rounds: [[[5, 1, 0], [5, 1, 0]]]),
        small(variant: 'numbers', rounds: [[[4, 0, 4]]]),
        small(rounds: []),
        small(rounds: 'x'),
        small(rounds: List.filled(flashMaxRounds + 1, [[0]])),
        small(rounds: [<List<int>>[]]),
        small(rounds: [List.generate(flashMaxPatterns + 1, (index) => [index])]),
        small(rounds: [[<int>[]]]),
        small(rounds: [[[9]]]),
        small(rounds: [[[-1]]]),
        small(rounds: [[[2, 1]]]),
        small(rounds: [[[1, 1]]]),
        small(rounds: [[[1.5]]]),
        small(rounds: [[[0, 1, 2, 3, 4]]]),
        small(rounds: [[[0, 1], [2]]]),
        small(rounds: [[[0, 1], [0, 1]]]),
        small(rounds: [['0']]),
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      // 每轮的组数可以不同，备用少的按自己的组数轮换。
      final uneven = _rules.decodePuzzle(small(rounds: [[[0]], [[1, 2], [3, 5], [6, 7]]]));
      expect(flashPattern(uneven, 0, 3), [0]);
      expect(flashPattern(uneven, 1, 4), [3, 5]);

      for (final bad in <Object?>[
        null,
        'x',
        [0],
        [['0']],
        [[36]],
        [[-1]],
        [[1.5]],
        [List.filled(flashMaxSide * flashMaxSide + 1, 0)],
        List.filled(flashMaxAttempts + 1, [0]),
      ]) {
        expect(() => _rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
      expect(_rules.decodeAnswer(List.filled(flashMaxAttempts, [35])), hasLength(flashMaxAttempts));
    });

    test('难易分与预计用时：同档相同，档与档之间往上走（预计用时五档约 45、70、110、160、230 秒）；解码进来的极端题面也落在 1–10', () {
      int? lowerScore, lowerSeconds;
      for (final MapEntry(key: tier, value: expected) in _tiers.entries) {
        for (var seed = 0; seed < 20; seed++) {
          final puzzle = _rules.generate(seed, tier).puzzle;
          expect(_rules.complexity(puzzle), expected.score, reason: '$tier $seed');
          expect(_rules.expectedSeconds(puzzle), expected.seconds, reason: '$tier $seed');
        }
        if (lowerScore != null) expect(expected.score, greaterThan(lowerScore));
        if (lowerSeconds != null) expect(expected.seconds, greaterThan(lowerSeconds * 1.3));
        lowerScore = expected.score;
        lowerSeconds = expected.seconds;
      }
      final easiest = FlashPuzzle(side: 3, variant: FlashVariant.spot, showMillis: flashMaxShowMillis, rounds: const [[[0]]]);
      final hardest = FlashPuzzle(side: 6, variant: FlashVariant.numbers, showMillis: flashMinShowMillis, rounds: List.filled(flashMaxRounds, [List.generate(18, (cell) => cell)]));
      expect(_rules.complexity(easiest), 1);
      expect(_rules.complexity(hardest), 10);
      expect(_rules.difficulty(hardest), inInclusiveRange(1, 10));
    });

    test('登记在记忆与反应，能进挑战；题面写法是第 2 版，碎片是最后一轮的格数', () {
      final game = playgroundCatalog.firstWhere((game) => game.id == 'flash');
      expect(game.group, memoryGroup);
      expect(game.challengeable, isTrue);
      expect(_rules.puzzleVersion, 2);
      expect(_rules.intake, PuzzleIntake.goal);
      for (final MapEntry(key: tier, value: expected) in _tiers.entries) {
        final draw = _rules.generate(2, tier);
        expect(_rules.fragment(draw.puzzle, draw.solution), expected.counts.last);
      }
    });
  });
}
