import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/flash/flash_page.dart';
import 'package:superxd/playground/puzzle/flash/flash_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';

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

final _app = GlobalKey();

String _name(int cell, int side) => '第${cell ~/ side + 1}行第${cell % side + 1}列';
Finder _cell(int cell, int side) => find.bySemanticsLabel(RegExp('^${_name(cell, side)}，'));
// 状态行：按先后点的题型在轮数后面写一个短词。
Finder _status(int round, int mistakes, {String? order}) => find.bySemanticsLabel(RegExp('· 第 $round/5 轮${order == null ? '' : ' · $order'} · 点错 $mistakes 次\$'));
Finder get _start => find.widgetWithText(FilledButton, '开始');

// 每格的读屏标签都是 state 给的样子。
void _expectBoard(int side, String Function(int cell) state) {
  for (var cell = 0; cell < side * side; cell++) {
    final label = '${_name(cell, side)}，${state(cell)}';
    expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
  }
}

String Function(int cell) _lit(List<int> pattern) => (cell) => pattern.contains(cell) ? '亮' : '未点亮';
String _dark(int cell) => '未点亮';

// 读屏节点本身不接点按（点按落在下面的棋盘上），按它的位置点。
Future<void> _tapCell(WidgetTester tester, int cell, int side) async {
  await tester.tapAt(tester.getCenter(_cell(cell, side)));
  await tester.pump();
}

// 画面上某一点的颜色（按逻辑像素取）：用来看格子亮没亮，不碰页面内部。
Future<Color> _colorAt(WidgetTester tester, Offset point) async => (await tester.runAsync(() async {
  final boundary = _app.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final bytes = (await image.toByteData())!;
  final offset = (point.dy.round() * image.width + point.dx.round()) * 4;
  image.dispose();
  return Color.fromARGB(bytes.getUint8(offset + 3), bytes.getUint8(offset), bytes.getUint8(offset + 1), bytes.getUint8(offset + 2));
}))!;

double _distance(Color left, Color right) => ((left.r - right.r).abs() + (left.g - right.g).abs() + (left.b - right.b).abs()) * 255;

// 记下触感：选择触感是点对（与开始），重震是点错。
List<String> _haptics(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') calls.add('${call.arguments}');
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

const _tick = 'HapticFeedbackType.selectionClick', _heavy = 'HapticFeedbackType.heavyImpact';

Future<PlaygroundStore> _open(WidgetTester tester, {required int seed, PuzzleTier tier = PuzzleTier.entry}) async {
  final store = PlaygroundStore.memory();
  await store.chooseTier('flash', tier);
  final game = playgroundCatalog.firstWhere((game) => game.id == 'flash');
  await tester.pumpWidget(RepaintBoundary(key: _app, child: MaterialApp(theme: campusTheme(), home: FlashPage(game: game, store: store, seeds: () => seed))));
  await tester.pumpAndSettle();
  return store;
}

// 一组从暗一下到熄灭（顺序与倒序一格接一格亮完）：before 是这一组前要等的（开局什么都不等，一轮点齐后等 flashHold，点错后等 flashReveal）。
Future<void> _showRound(WidgetTester tester, FlashPuzzle puzzle, List<int> shown, {Duration before = Duration.zero}) async {
  if (before > Duration.zero) await tester.pump(before);
  await tester.pump(flashLead);
  await tester.pump(Duration(milliseconds: flashExposure(puzzle, shown.length)));
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

  group('记忆闪光对局页', () {
    testWidgets('位置记忆：开始前点格不算；先暗一下再亮，亮着点了不算也不震；熄灭后点对保持点亮，点错重震、亮出漏掉的格，再换下一组重来', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      await _open(tester, seed: 1);
      final puzzle = _rules.generate(1, PuzzleTier.entry).puzzle;
      final first = flashPattern(puzzle, 0, 0);
      final outside = _outside(puzzle, first);
      expect(_status(1, 0), findsOneWidget);
      expect(find.bySemanticsLabel('记住亮起的格，再点出来'), findsOneWidget);
      // 开始前读屏不放格子，直接走到「开始」。
      expect(find.bySemanticsLabel('开始'), findsOneWidget);
      expect(_cell(0, 4), findsNothing);

      // 开始按钮盖在棋盘中间：点卡片的两个角（归角上的格）什么都不发生。
      final card = tester.getRect(find.descendant(of: find.byType(FlashPage), matching: find.byType(CampusSurface)));
      await tester.tapAt(card.topLeft + const Offset(12, 12));
      await tester.pump();
      await tester.tapAt(card.bottomRight - const Offset(12, 12));
      await tester.pump();
      expect(haptics, isEmpty);
      expect(_start, findsOneWidget);
      expect(_cell(0, 4), findsNothing);

      await tester.tap(_start);
      await tester.pump();
      expect(haptics, [_tick]);
      expect(_start, findsNothing);
      // 先暗一下，再亮；亮着时播报亮的是哪几格。
      _expectBoard(4, _dark);
      await tester.pump(flashLead);
      _expectBoard(4, _lit(first));
      final announcement = find.bySemanticsLabel('亮起 ${first.length} 格：${first.map((cell) => _name(cell, 4)).join('、')}');
      expect(tester.getSemantics(announcement), isSemantics(isLiveRegion: true));

      // 亮着时点了不算、不震。
      await _tapCell(tester, first.first, 4);
      await _tapCell(tester, outside, 4);
      expect(haptics, hasLength(1));
      expect(_status(1, 0), findsOneWidget);
      _expectBoard(4, _lit(first));

      await tester.pump(Duration(milliseconds: puzzle.showMillis));
      _expectBoard(4, _dark);
      expect(find.bySemanticsLabel('点出刚才亮的格'), findsOneWidget);

      // 点对一格保持点亮；再点它不响应。
      await _tapCell(tester, first.first, 4);
      expect(haptics, [_tick, _tick]);
      _expectBoard(4, (cell) => cell == first.first ? '已点亮' : '未点亮');
      await _tapCell(tester, first.first, 4);
      expect(haptics, hasLength(2));

      // 点错：重震，记一次错，标出点错的格与漏掉的格；亮答案时点了不算。
      await _tapCell(tester, outside, 4);
      expect(haptics.last, _heavy);
      expect(_status(1, 1), findsOneWidget);
      String reveal(int cell) => cell == first.first ? '已点亮' : cell == outside ? '点错了' : first.contains(cell) ? '应该亮' : '未点亮';
      _expectBoard(4, reveal);
      expect(find.bySemanticsLabel('点错了，换一组重来'), findsOneWidget);
      await _tapCell(tester, first.last, 4);
      expect(haptics, hasLength(3));
      _expectBoard(4, reveal);

      // 换这一轮的第二组重来，点齐进第二轮。
      final second = flashPattern(puzzle, 0, 1);
      expect(second, isNot(first));
      await tester.pump(flashReveal);
      await tester.pump(flashLead);
      _expectBoard(4, _lit(second));
      await tester.pump(Duration(milliseconds: puzzle.showMillis));
      for (final cell in second.reversed) {
        await _tapCell(tester, cell, 4);
      }
      expect(_status(1, 1), findsOneWidget, reason: '点齐后停一下时棋盘还是这一轮，状态行也不先跳');
      expect(find.bySemanticsLabel('这一轮全对'), findsOneWidget);
      _expectBoard(4, (cell) => second.contains(cell) ? '已点亮' : '未点亮');
      await tester.pump(flashHold);
      expect(_status(2, 1), findsOneWidget);
      await tester.pump(flashLead);
      _expectBoard(4, _lit(flashPattern(puzzle, 1, 0)));
      semantics.dispose();
    });

    testWidgets('顺序：格子一个接一个亮（同一时刻只有一格亮，格间暗一下），熄灭后按亮的先后点；格对先后错算点错，并写出每格该第几个点', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      await _open(tester, seed: 8, tier: PuzzleTier.normal);
      final puzzle = _rules.generate(8, PuzzleTier.normal).puzzle;
      final first = flashPattern(puzzle, 0, 0);
      expect(first, flashShown(puzzle, 0, 0));
      expect(_status(1, 0, order: '按顺序'), findsOneWidget);
      expect(find.bySemanticsLabel('记住亮的先后，再按顺序点'), findsOneWidget);
      await tester.tap(_start);
      await tester.pump();
      await tester.pump(flashLead);
      expect(find.bySemanticsLabel('依次亮起 ${first.length} 格：${first.map((cell) => _name(cell, 5)).join('、')}'), findsOneWidget);
      for (var step = 0; step < first.length; step++) {
        _expectBoard(5, (cell) => cell == first[step] ? '亮' : '未点亮');
        // 亮着时点了不算、不震。
        await _tapCell(tester, first[step], 5);
        expect(haptics, hasLength(1));
        await tester.pump(Duration(milliseconds: puzzle.showMillis));
        if (step + 1 < first.length) {
          _expectBoard(5, _dark);
          expect(find.text('记住亮的先后'), findsOneWidget);
          await tester.pump(Duration(milliseconds: puzzle.gapMillis));
        }
      }
      _expectBoard(5, _dark);
      expect(find.bySemanticsLabel('按亮的顺序点'), findsOneWidget);

      // 点对第一格，跳过第二格先点第三格：格在这一组里，但先后不对，算点错。
      await _tapCell(tester, first[0], 5);
      expect(haptics.last, _tick);
      _expectBoard(5, (cell) => cell == first[0] ? '已点亮' : '未点亮');
      await _tapCell(tester, first[2], 5);
      expect(haptics.last, _heavy);
      expect(_status(1, 1, order: '按顺序'), findsOneWidget);
      _expectBoard(5, (cell) => cell == first[0] ? '已点亮' : cell == first[2] ? '点错了' : first.contains(cell) ? '应该第 ${first.indexOf(cell) + 1} 个点' : '未点亮');

      // 换下一组，照亮的先后点齐过这一轮。
      final second = flashPattern(puzzle, 0, 1);
      await _showRound(tester, puzzle, second, before: flashReveal);
      _expectBoard(5, _dark);
      for (final cell in second) {
        await _tapCell(tester, cell, 5);
      }
      expect(find.bySemanticsLabel('这一轮全对'), findsOneWidget);
      await tester.pump(flashHold);
      expect(_status(2, 1, order: '按顺序'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('倒序：照亮的先后点，第一下就算点错（最后亮的该第 1 个点）；倒过来点齐过这一轮', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      await _open(tester, seed: 9, tier: PuzzleTier.hard);
      final puzzle = _rules.generate(9, PuzzleTier.hard).puzzle;
      final shown = flashShown(puzzle, 0, 0), target = flashPattern(puzzle, 0, 0);
      expect(target, shown.reversed.toList());
      expect(_status(1, 0, order: '倒着点'), findsOneWidget);
      await tester.tap(_start);
      await tester.pump();
      await tester.pump(flashLead);
      _expectBoard(6, (cell) => cell == shown.first ? '亮' : '未点亮');
      await tester.pump(Duration(milliseconds: flashExposure(puzzle, shown.length)));
      expect(find.bySemanticsLabel('倒着点，最后亮的先点'), findsOneWidget);

      await _tapCell(tester, shown.first, 6);
      expect(haptics.last, _heavy);
      _expectBoard(6, (cell) => cell == shown.first ? '点错了' : target.contains(cell) ? '应该第 ${target.indexOf(cell) + 1} 个点' : '未点亮');
      expect(find.bySemanticsLabel('${_name(shown.last, 6)}，应该第 1 个点'), findsOneWidget);

      final next = flashPattern(puzzle, 0, 1);
      expect(next, flashShown(puzzle, 0, 1).reversed.toList());
      await _showRound(tester, puzzle, next, before: flashReveal);
      for (final cell in next) {
        await _tapCell(tester, cell, 6);
      }
      expect(find.bySemanticsLabel('这一轮全对'), findsOneWidget);
      expect(_status(1, 1, order: '倒着点'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('数字顺序：亮着时块上读数、块外的格不响应；点 1 全部藏成空白块，跳过数字算点错并写出每块该第几个；到时间没点也藏', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      await _open(tester, seed: 7, tier: PuzzleTier.expert);
      final puzzle = _rules.generate(7, PuzzleTier.expert).puzzle;
      final first = flashPattern(puzzle, 0, 0);
      final outside = _outside(puzzle, first);
      expect(_status(1, 0, order: '从小到大'), findsOneWidget);
      expect(find.bySemanticsLabel('记住数字的位置，从小到大点'), findsOneWidget);
      await tester.tap(_start);
      await tester.pump();
      await tester.pump(flashLead);
      String numbered(int cell) => first.contains(cell) ? '数字 ${first.indexOf(cell) + 1}' : '未点亮';
      _expectBoard(6, numbered);
      expect(find.bySemanticsLabel('${first.length} 个数：${[for (final (index, cell) in first.indexed) '${index + 1} 在${_name(cell, 6)}'].join('、')}'), findsOneWidget);

      // 块外的格不响应：不震、数字也不藏。
      await _tapCell(tester, outside, 6);
      expect(haptics, hasLength(1));
      _expectBoard(6, numbered);

      // 亮着时点 1：全部藏起，这一下算点对。
      await _tapCell(tester, first[0], 6);
      expect(haptics, [_tick, _tick]);
      _expectBoard(6, (cell) => cell == first[0] ? '已点亮' : first.contains(cell) ? '空白块' : '未点亮');
      expect(find.bySemanticsLabel('从 1 开始从小到大点'), findsOneWidget);
      // 空白块和暗格画得不一样。
      await tester.pump(const Duration(milliseconds: 200));
      final block = await _colorAt(tester, tester.getCenter(_cell(first[1], 6)));
      final plain = await _colorAt(tester, tester.getCenter(_cell(outside, 6)));
      expect(_distance(block, plain), greaterThan(20));
      // 作答时块外的格也不响应。
      await _tapCell(tester, outside, 6);
      expect(haptics, hasLength(2));

      // 跳过 2 先点 3：点错，每块写出该第几个点。
      await _tapCell(tester, first[2], 6);
      expect(haptics.last, _heavy);
      expect(_status(1, 1, order: '从小到大'), findsOneWidget);
      _expectBoard(6, (cell) => cell == first[0] ? '已点亮' : cell == first[2] ? '点错了' : first.contains(cell) ? '应该第 ${first.indexOf(cell) + 1} 个点' : '未点亮');

      // 下一组到时间没点也藏起，按从小到大点齐过这一轮。
      final second = flashPattern(puzzle, 0, 1);
      await tester.pump(flashReveal);
      await tester.pump(flashLead);
      _expectBoard(6, (cell) => second.contains(cell) ? '数字 ${second.indexOf(cell) + 1}' : '未点亮');
      await tester.pump(Duration(milliseconds: flashExposure(puzzle, second.length)));
      _expectBoard(6, (cell) => second.contains(cell) ? '空白块' : '未点亮');
      for (final cell in second) {
        await _tapCell(tester, cell, 6);
      }
      expect(find.bySemanticsLabel('这一轮全对'), findsOneWidget);
      await tester.pump(flashHold);
      expect(_status(2, 1, order: '从小到大'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('五轮都点对：收尾一圈一圈亮一下再弹新纪录，记下成绩，可换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = await _open(tester, seed: 2);
      final puzzle = _rules.generate(2, PuzzleTier.entry).puzzle;
      final last = flashPattern(puzzle, flashRounds - 1, 0);
      late Color dark;
      await tester.tap(_start);
      await tester.pump();
      // 收尾时看最后一轮没亮的一格：它在收尾之前一直是暗着的样子。
      final probe = tester.getCenter(_cell(_outside(puzzle, last), 4));
      for (var round = 0; round < flashRounds; round++) {
        await _showRound(tester, puzzle, flashShown(puzzle, round, 0), before: round == 0 ? Duration.zero : flashHold);
        expect(_status(round + 1, 0), findsOneWidget);
        // 熄灭的过渡走完再取暗着的样子。
        await tester.pump(const Duration(milliseconds: 200));
        if (round == flashRounds - 1) dark = await _colorAt(tester, probe);
        for (final cell in flashPattern(puzzle, round, 0)) {
          await _tapCell(tester, cell, 4);
        }
      }
      expect(_status(5, 0), findsOneWidget);
      // 收尾：没点的格也一圈一圈亮一下，亮完回到暗着的样子，才弹结果。
      var brightest = 0.0;
      for (var frame = 0; frame < 40 && find.text('新纪录').evaluate().isEmpty; frame++) {
        brightest = math.max(brightest, _distance(await _colorAt(tester, probe), dark));
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(brightest, greaterThan(60));
      expect(find.text('新纪录'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('^入门 · 5 轮 · 一次没错')), findsOneWidget);
      expect(store.best('flash', PuzzleTier.entry), isNotNull);

      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      expect(store.tierOf('flash'), PuzzleTier.easy);
      expect(_status(1, 0), findsOneWidget);
      await tester.tap(_start);
      await tester.pump();
      _expectBoard(5, _dark);
      semantics.dispose();
    });

    testWidgets('减少动画：照样亮起熄灭，只是不渐变；点错后结果里写错的次数，解开直接弹结果', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _open(tester, seed: 3);
      final puzzle = _rules.generate(3, PuzzleTier.entry).puzzle;
      final first = flashPattern(puzzle, 0, 0);
      await tester.tap(_start);
      await tester.pump();
      final center = tester.getCenter(_cell(first.first, 4));
      final dark = await _colorAt(tester, center);
      await tester.pump(flashLead);
      final lit = await _colorAt(tester, center);
      expect(_distance(lit, dark), greaterThan(60));
      _expectBoard(4, _lit(first));
      // 一亮就到位，没有渐变。
      await tester.pump(const Duration(milliseconds: 60));
      expect(_distance(await _colorAt(tester, center), lit), lessThan(1));
      // 到点直接熄灭。
      await tester.pump(Duration(milliseconds: puzzle.showMillis));
      expect(_distance(await _colorAt(tester, center), dark), lessThan(1));
      _expectBoard(4, _dark);

      // 第一轮点错一次，之后都点对。
      await _tapCell(tester, _outside(puzzle, first), 4);
      await _showRound(tester, puzzle, flashShown(puzzle, 0, 1), before: flashReveal);
      for (var round = 0; round < flashRounds; round++) {
        if (round > 0) await _showRound(tester, puzzle, flashShown(puzzle, round, 0), before: flashHold);
        for (final cell in flashPattern(puzzle, round, round == 0 ? 1 : 0)) {
          await _tapCell(tester, cell, 4);
        }
      }
      await tester.pump();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^入门 · 5 轮 · 点错 1 次')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('减少动画下的顺序：每格亮满题面给的时长、格间照样暗一下，不被压短', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _open(tester, seed: 4, tier: PuzzleTier.normal);
      final puzzle = _rules.generate(4, PuzzleTier.normal).puzzle;
      final first = flashShown(puzzle, 0, 0);
      await tester.tap(_start);
      await tester.pump();
      final center = tester.getCenter(_cell(first[1], 5));
      final dark = await _colorAt(tester, center);
      await tester.pump(flashLead + Duration(milliseconds: puzzle.showMillis + puzzle.gapMillis));
      final lit = await _colorAt(tester, center);
      expect(_distance(lit, dark), greaterThan(60));
      await tester.pump(Duration(milliseconds: puzzle.showMillis - 10));
      expect(_distance(await _colorAt(tester, center), lit), lessThan(1), reason: '快到时长还亮着');
      await tester.pump(const Duration(milliseconds: 10));
      expect(_distance(await _colorAt(tester, center), dark), lessThan(1));
      _expectBoard(5, _dark);
      semantics.dispose();
    });

    testWidgets('亮着时切到后台：回来先暗一下再把这一组重新亮一遍（顺序从第一格重新亮）', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, seed: 4, tier: PuzzleTier.normal);
      final puzzle = _rules.generate(4, PuzzleTier.normal).puzzle;
      final first = flashShown(puzzle, 0, 0);
      await tester.tap(_start);
      await tester.pump();
      await tester.pump(flashLead + Duration(milliseconds: puzzle.showMillis + puzzle.gapMillis));
      _expectBoard(5, (cell) => cell == first[1] ? '亮' : '未点亮');
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      // 在后台不往下走（不进作答）。
      await tester.pump(Duration(milliseconds: flashExposure(puzzle, first.length) * 2));
      for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      _expectBoard(5, _dark);
      expect(find.bySemanticsLabel('记住亮的先后'), findsOneWidget);
      await tester.pump(flashLead);
      _expectBoard(5, (cell) => cell == first[0] ? '亮' : '未点亮');
      await tester.pump(Duration(milliseconds: flashExposure(puzzle, first.length)));
      _expectBoard(5, _dark);
      await _tapCell(tester, first[0], 5);
      _expectBoard(5, (cell) => cell == first[0] ? '已点亮' : '未点亮');
      expect(_status(1, 0, order: '按顺序'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('从头来与换题：回到开始前，状态清零', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, seed: 5);
      final puzzle = _rules.generate(5, PuzzleTier.entry).puzzle;
      await tester.tap(_start);
      await tester.pump();
      await _showRound(tester, puzzle, flashShown(puzzle, 0, 0));
      await _tapCell(tester, _outside(puzzle, flashPattern(puzzle, 0, 0)), 4);
      expect(_status(1, 1), findsOneWidget);
      // 对局中计时器每秒出帧，pumpAndSettle 等不到停：菜单开合只推进固定时长。
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('这一题从头来'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_start, findsOneWidget);
      expect(_status(1, 0), findsOneWidget);
      expect(_cell(0, 4), findsNothing);
      // 等着的下一组不会再亮起来，停在开始前。
      await tester.pump(flashReveal + flashLead);
      expect(_start, findsOneWidget);
      expect(_cell(0, 4), findsNothing);

      await tester.tap(_start);
      await tester.pump();
      await _showRound(tester, puzzle, flashShown(puzzle, 0, 0));
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('换一道题'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_start, findsOneWidget);
      expect(_status(1, 0), findsOneWidget);
      await tester.pump(flashReveal + flashLead);
      expect(_start, findsOneWidget);
      expect(_cell(0, 4), findsNothing);
      semantics.dispose();
    });

    testWidgets('6×6 在 360dp 宽、1.3 倍字号下放得下，每格触区不小于 48，数字亮着时也不溢出', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view
        ..physicalSize = const Size(1080, 1920)
        ..devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final tier in [PuzzleTier.hard, PuzzleTier.expert]) {
        await _open(tester, seed: 6, tier: tier);
        expect(tester.takeException(), isNull);
        await tester.tap(_start);
        await tester.pump();
        await tester.pump(flashLead);
        expect(tester.takeException(), isNull);
        for (var cell = 0; cell < 36; cell++) {
          final rect = tester.getRect(_cell(cell, 6));
          expect(rect.width, greaterThanOrEqualTo(48), reason: '$tier $cell');
          expect(rect.height, greaterThanOrEqualTo(48), reason: '$tier $cell');
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(360));
        }
        await tester.pumpWidget(const SizedBox());
      }
      semantics.dispose();
    });
  });
}
