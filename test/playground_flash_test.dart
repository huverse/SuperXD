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
import 'package:superxd/theme/campus_theme.dart';

const _rules = FlashRules();

// 每档的边长、5 轮各亮几格、亮的毫秒数与难度分（同 flash_rules.dart 的 _tiers 与 difficulty 注释）。
const _tiers = {
  PuzzleTier.entry: (side: 3, counts: [3, 3, 3, 4, 4], show: 1500, score: 2),
  PuzzleTier.easy: (side: 4, counts: [4, 4, 4, 5, 5], show: 1400, score: 3),
  PuzzleTier.normal: (side: 5, counts: [6, 6, 6, 7, 7], show: 1300, score: 5),
  PuzzleTier.hard: (side: 6, counts: [8, 8, 8, 9, 9], show: 1200, score: 7),
  PuzzleTier.expert: (side: 6, counts: [10, 10, 11, 11, 12], show: 1000, score: 9),
};

// 不在这一组图案里的第一格（拿来点错）。
int _outside(FlashPuzzle puzzle, List<int> pattern) => List.generate(puzzle.side * puzzle.side, (cell) => cell).firstWhere((cell) => !pattern.contains(cell));

// 第 round 轮第 attempt 次：先点对 hits 格再点错一格。
List<int> _miss(FlashPuzzle puzzle, int round, int attempt, {int hits = 0}) {
  final pattern = flashPattern(puzzle, round, attempt);
  return [...pattern.take(hits), _outside(puzzle, pattern)];
}

final _app = GlobalKey();

String _name(int cell, int side) => '第${cell ~/ side + 1}行第${cell % side + 1}列';
Finder _cell(int cell, int side) => find.bySemanticsLabel(RegExp('^${_name(cell, side)}，'));
Finder _status(int round, int mistakes) => find.bySemanticsLabel(RegExp('· 第 $round/5 轮 · 点错 $mistakes 次\$'));
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

Future<PlaygroundStore> _open(WidgetTester tester, {required int seed, PuzzleTier tier = PuzzleTier.entry}) async {
  final store = PlaygroundStore.memory();
  await store.chooseTier('flash', tier);
  final game = playgroundCatalog.firstWhere((game) => game.id == 'flash');
  await tester.pumpWidget(RepaintBoundary(key: _app, child: MaterialApp(theme: campusTheme(), home: FlashPage(game: game, store: store, seeds: () => seed))));
  await tester.pumpAndSettle();
  return store;
}

// 一轮从暗一下到熄灭：before 是这一轮前要等的（开局什么都不等，一轮点齐后等 flashHold，点错后等 flashReveal）。
Future<void> _showRound(WidgetTester tester, FlashPuzzle puzzle, {Duration before = Duration.zero}) async {
  if (before > Duration.zero) await tester.pump(before);
  await tester.pump(flashLead);
  await tester.pump(Duration(milliseconds: puzzle.showMillis));
}

void main() {
  group('记忆闪光规则', () {
    test('每档出题：参数对得上，每组在棋盘内、升序不重格、不成整条线，整道题不重样；参考解一次没错地解开；可复现', () {
      for (final MapEntry(key: tier, value: expected) in _tiers.entries) {
        for (var seed = 0; seed < 30; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          final reason = '$tier $seed';
          expect(puzzle.side, expected.side, reason: reason);
          expect(puzzle.showMillis, expected.show, reason: reason);
          expect(puzzle.rounds, hasLength(flashRounds), reason: reason);
          final seen = <String>{};
          for (final (round, patterns) in puzzle.rounds.indexed) {
            expect(patterns, hasLength(flashPatternsPerRound), reason: reason);
            for (final pattern in patterns) {
              expect(pattern, hasLength(expected.counts[round]), reason: '$reason 第 $round 轮');
              expect(pattern, everyElement(inInclusiveRange(0, puzzle.side * puzzle.side - 1)), reason: reason);
              for (var index = 1; index < pattern.length; index++) {
                expect(pattern[index], greaterThan(pattern[index - 1]), reason: '$reason $pattern');
              }
              expect(flashHasLine(puzzle.side, pattern.toSet()), isFalse, reason: '$reason $pattern');
              expect(seen.add(pattern.join(',')), isTrue, reason: '$reason 重样 $pattern');
            }
          }
          expect(draw.solution, hasLength(flashRounds));
          expect(flashMistakes(puzzle, draw.solution), 0, reason: reason);
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: reason);
        }
      }
      String encoded(int seed, PuzzleTier tier) => jsonEncode(_rules.encodePuzzle(_rules.generate(seed, tier).puzzle));
      expect(encoded(7, PuzzleTier.hard), encoded(7, PuzzleTier.hard));
      expect(encoded(7, PuzzleTier.expert), isNot(encoded(8, PuzzleTier.expert)));
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

    test('整行、整列、两条对角线全亮才算成线', () {
      expect(flashHasLine(3, {0, 1, 2}), isTrue);
      expect(flashHasLine(3, {1, 4, 7}), isTrue);
      expect(flashHasLine(3, {0, 4, 8}), isTrue);
      expect(flashHasLine(3, {2, 4, 6}), isTrue);
      expect(flashHasLine(3, {0, 1, 5}), isFalse);
      expect(flashHasLine(4, {0, 1, 2, 7}), isFalse);
      expect(flashHasLine(4, {3, 6, 9, 12, 0}), isTrue);
    });

    test('点一格：已点亮的不响应、在图案里算点对（点齐算过了这一轮）、不在图案里算点错', () {
      expect(flashTap([1, 4, 7], {1}, 1), FlashTap.repeated);
      expect(flashTap([1, 4, 7], {1}, 4), FlashTap.hit);
      expect(flashTap([1, 4, 7], {1, 4}, 7), FlashTap.cleared);
      expect(flashTap([1, 4, 7], {1}, 2), FlashTap.missed);
      expect(flashTap([1, 4, 7], {}, 0), FlashTap.missed);
    });

    test('按规则判定：顺序不限；少点、多点、点已点亮的、点棋盘外、空的一次、点错后接着点、点错后没换图案、轮数不够或多出、超长都不算', () {
      final draw = _rules.generate(3, PuzzleTier.entry);
      final puzzle = draw.puzzle, solution = draw.solution;
      final first = solution.first, rest = solution.sublist(1);
      final outside = _outside(puzzle, first);
      expect(_rules.solved(puzzle, [for (final taps in solution) taps.reversed.toList()]), isTrue);
      // 少点：最后一轮差一格。
      expect(_rules.solved(puzzle, [...solution.take(4), solution.last.sublist(1)]), isFalse);
      // 多点：点齐以后又点一格。
      expect(_rules.solved(puzzle, [[...first, outside], ...rest]), isFalse);
      expect(_rules.solved(puzzle, [...solution.take(4), [...solution.last, _outside(puzzle, solution.last)]]), isFalse);
      // 点已点亮的格：页面里不响应，答案里不该有。
      expect(_rules.solved(puzzle, [[first.first, ...first], ...rest]), isFalse);
      // 点棋盘外（3×3 的第 9 格）不算点错，整份答案不合规。
      expect(_rules.solved(puzzle, [[9], first, ...rest]), isFalse);
      expect(_rules.solved(puzzle, [[], ...solution]), isFalse);
      // 点错后接着点：点错必须是这一次的最后一下。
      expect(_rules.solved(puzzle, [[outside, ...first], ...rest]), isFalse);
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

    test('错的次数从答案里数得出：每次点错换这一轮的下一组，备用用完从第一组轮换', () {
      final puzzle = _rules.generate(5, PuzzleTier.easy).puzzle;
      List<int> clear(int round, int attempt) => flashPattern(puzzle, round, attempt).reversed.toList();
      expect(flashPattern(puzzle, 4, flashPatternsPerRound), puzzle.rounds[4][0]);
      expect(flashPattern(puzzle, 4, flashPatternsPerRound + 1), puzzle.rounds[4][1]);
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
      expect(flashMistakes(puzzle, answer), 10);
      expect(_rules.solved(puzzle, answer), isTrue);
      // 轮换错一位（第 8 次还点第一组）就不算。
      expect(flashMistakes(puzzle, [...answer.sublist(0, answer.length - 1), clear(4, 0)]), isNull);
      expect(flashMistakes(puzzle, _rules.generate(5, PuzzleTier.easy).solution), 0);
    });

    test('编解码往返，坏输入抛 FormatException', () {
      final draw = _rules.generate(11, PuzzleTier.expert);
      final puzzle = _rules.decodePuzzle(jsonDecode(jsonEncode(_rules.encodePuzzle(draw.puzzle))));
      expect(puzzle.side, 6);
      expect(puzzle.showMillis, 1000);
      expect(jsonEncode(_rules.encodePuzzle(puzzle)), jsonEncode(_rules.encodePuzzle(draw.puzzle)));
      final answer = [_miss(draw.puzzle, 0, 0, hits: 3), flashPattern(draw.puzzle, 0, 1), ...draw.solution.sublist(1)];
      final decoded = _rules.decodeAnswer(jsonDecode(jsonEncode(_rules.encodeAnswer(answer))));
      expect(flashMistakes(puzzle, decoded), 1);

      Map<String, Object?> small({Object? side = 3, Object? show = 1500, Object? rounds}) => {
        'side': side,
        'show': show,
        'rounds': rounds ?? [[[0, 1, 5], [2, 3, 7]]],
      };
      expect(_rules.decodePuzzle(small()).rounds.single, [[0, 1, 5], [2, 3, 7]]);
      for (final bad in <Object?>[
        null,
        'x',
        [3],
        small(side: 2),
        small(side: 7),
        small(side: '3'),
        small(show: flashMinShowMillis - 1),
        small(show: flashMaxShowMillis + 1),
        small(show: 1500.5),
        {'side': 3, 'show': 1500},
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

    test('难度分：同档相同，档与档之间往上走；解码进来的极端题面也落在 1–10', () {
      int? lower;
      for (final MapEntry(key: tier, value: expected) in _tiers.entries) {
        for (var seed = 0; seed < 20; seed++) {
          expect(_rules.difficulty(_rules.generate(seed, tier).puzzle), expected.score, reason: '$tier $seed');
        }
        if (lower != null) expect(expected.score, greaterThan(lower));
        lower = expected.score;
      }
      final easiest = FlashPuzzle(side: 3, showMillis: flashMaxShowMillis, rounds: const [[[0]]]);
      final hardest = FlashPuzzle(side: 6, showMillis: flashMinShowMillis, rounds: List.filled(flashMaxRounds, [List.generate(18, (cell) => cell)]));
      expect(_rules.difficulty(easiest), 1);
      expect(_rules.difficulty(hardest), 10);
    });

    test('登记在记忆与反应，能进挑战', () {
      final game = playgroundCatalog.firstWhere((game) => game.id == 'flash');
      expect(game.group, memoryGroup);
      expect(game.challengeable, isTrue);
    });
  });

  group('记忆闪光对局页', () {
    testWidgets('开始前点格不算；先暗一下再亮，亮着点了不算也不震；熄灭后点对保持点亮，点错重震、亮出漏掉的格，再换下一组重来', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      await _open(tester, seed: 1);
      final puzzle = _rules.generate(1, PuzzleTier.entry).puzzle;
      final first = flashPattern(puzzle, 0, 0);
      final outside = _outside(puzzle, first);
      expect(_status(1, 0), findsOneWidget);
      expect(find.bySemanticsLabel('记住亮起的格，再点出来'), findsOneWidget);
      _expectBoard(3, _dark);

      // 开始按钮盖在棋盘中间：点角上的格什么都不发生。
      await _tapCell(tester, 0, 3);
      await _tapCell(tester, 8, 3);
      expect(haptics, isEmpty);
      _expectBoard(3, _dark);
      expect(_start, findsOneWidget);

      await tester.tap(_start);
      await tester.pump();
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      expect(_start, findsNothing);
      // 先暗一下，再亮；亮着时播报亮的是哪几格。
      _expectBoard(3, _dark);
      await tester.pump(flashLead);
      _expectBoard(3, _lit(first));
      final announcement = find.bySemanticsLabel('亮起 ${first.length} 格：${first.map((cell) => _name(cell, 3)).join('、')}');
      expect(tester.getSemantics(announcement), isSemantics(isLiveRegion: true));

      // 亮着时点了不算、不震。
      await _tapCell(tester, first.first, 3);
      await _tapCell(tester, outside, 3);
      expect(haptics, hasLength(1));
      expect(_status(1, 0), findsOneWidget);
      _expectBoard(3, _lit(first));

      await tester.pump(Duration(milliseconds: puzzle.showMillis));
      _expectBoard(3, _dark);
      expect(find.bySemanticsLabel('点出刚才亮的格'), findsOneWidget);

      // 点对一格保持点亮；再点它不响应。
      await _tapCell(tester, first.first, 3);
      expect(haptics, hasLength(2));
      expect(haptics.last, 'HapticFeedbackType.selectionClick');
      _expectBoard(3, (cell) => cell == first.first ? '已点亮' : '未点亮');
      await _tapCell(tester, first.first, 3);
      expect(haptics, hasLength(2));

      // 点错：重震，记一次错，标出点错的格与漏掉的格；亮答案时点了不算。
      await _tapCell(tester, outside, 3);
      expect(haptics.last, 'HapticFeedbackType.heavyImpact');
      expect(_status(1, 1), findsOneWidget);
      String reveal(int cell) => cell == first.first ? '已点亮' : cell == outside ? '点错了' : first.contains(cell) ? '应该亮' : '未点亮';
      _expectBoard(3, reveal);
      expect(find.bySemanticsLabel('点错了，换一组重来'), findsOneWidget);
      await _tapCell(tester, first.last, 3);
      expect(haptics, hasLength(3));
      _expectBoard(3, reveal);

      // 换这一轮的第二组重来，点齐进第二轮。
      final second = flashPattern(puzzle, 0, 1);
      expect(second, isNot(first));
      await tester.pump(flashReveal);
      await tester.pump(flashLead);
      _expectBoard(3, _lit(second));
      await tester.pump(Duration(milliseconds: puzzle.showMillis));
      for (final cell in second.reversed) {
        await _tapCell(tester, cell, 3);
      }
      expect(_status(2, 1), findsOneWidget);
      expect(find.bySemanticsLabel('这一轮全对'), findsOneWidget);
      _expectBoard(3, (cell) => second.contains(cell) ? '已点亮' : '未点亮');
      await tester.pump(flashHold);
      await tester.pump(flashLead);
      _expectBoard(3, _lit(flashPattern(puzzle, 1, 0)));
      semantics.dispose();
    });

    testWidgets('五轮都点对：收尾一圈一圈亮一下再弹新纪录，记下成绩，可换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = await _open(tester, seed: 2);
      final puzzle = _rules.generate(2, PuzzleTier.entry).puzzle;
      final last = flashPattern(puzzle, flashRounds - 1, 0);
      // 收尾时看最后一轮没亮的一格：它在收尾之前一直是暗着的样子。
      final probe = tester.getCenter(_cell(_outside(puzzle, last), 3));
      late Color dark;
      await tester.tap(_start);
      await tester.pump();
      for (var round = 0; round < flashRounds; round++) {
        await _showRound(tester, puzzle, before: round == 0 ? Duration.zero : flashHold);
        expect(_status(round + 1, 0), findsOneWidget);
        // 熄灭的过渡走完再取暗着的样子。
        await tester.pump(const Duration(milliseconds: 200));
        if (round == flashRounds - 1) dark = await _colorAt(tester, probe);
        for (final cell in flashPattern(puzzle, round, 0)) {
          await _tapCell(tester, cell, 3);
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
      expect(_start, findsOneWidget);
      expect(_status(1, 0), findsOneWidget);
      _expectBoard(4, _dark);
      semantics.dispose();
    });

    testWidgets('减少动画：照样亮起熄灭，只是不渐变；点错后结果里写错的次数，解开直接弹结果', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _open(tester, seed: 3);
      final puzzle = _rules.generate(3, PuzzleTier.entry).puzzle;
      final first = flashPattern(puzzle, 0, 0);
      final center = tester.getCenter(_cell(first.first, 3));
      await tester.tap(_start);
      await tester.pump();
      final dark = await _colorAt(tester, center);
      await tester.pump(flashLead);
      final lit = await _colorAt(tester, center);
      expect(_distance(lit, dark), greaterThan(60));
      _expectBoard(3, _lit(first));
      // 一亮就到位，没有渐变。
      await tester.pump(const Duration(milliseconds: 60));
      expect(_distance(await _colorAt(tester, center), lit), lessThan(1));
      // 到点直接熄灭。
      await tester.pump(Duration(milliseconds: puzzle.showMillis));
      expect(_distance(await _colorAt(tester, center), dark), lessThan(1));
      _expectBoard(3, _dark);

      // 第一轮点错一次，之后都点对。
      await _tapCell(tester, _outside(puzzle, first), 3);
      await _showRound(tester, puzzle, before: flashReveal);
      for (var round = 0; round < flashRounds; round++) {
        if (round > 0) await _showRound(tester, puzzle, before: flashHold);
        for (final cell in flashPattern(puzzle, round, round == 0 ? 1 : 0)) {
          await _tapCell(tester, cell, 3);
        }
      }
      await tester.pump();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^入门 · 5 轮 · 点错 1 次')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('亮着时切到后台：回来先暗一下再把这一组重新亮一遍', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, seed: 4);
      final puzzle = _rules.generate(4, PuzzleTier.entry).puzzle;
      final first = flashPattern(puzzle, 0, 0);
      await tester.tap(_start);
      await tester.pump();
      await tester.pump(flashLead);
      _expectBoard(3, _lit(first));
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      // 在后台不往下走（不进作答）。
      await tester.pump(Duration(milliseconds: puzzle.showMillis * 2));
      for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      _expectBoard(3, _dark);
      expect(find.bySemanticsLabel('记住亮起的格'), findsOneWidget);
      await tester.pump(flashLead);
      _expectBoard(3, _lit(first));
      await tester.pump(Duration(milliseconds: puzzle.showMillis));
      _expectBoard(3, _dark);
      await _tapCell(tester, first.first, 3);
      _expectBoard(3, (cell) => cell == first.first ? '已点亮' : '未点亮');
      expect(_status(1, 0), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('从头来与换题：回到开始前，状态清零', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, seed: 5);
      final puzzle = _rules.generate(5, PuzzleTier.entry).puzzle;
      await tester.tap(_start);
      await tester.pump();
      await _showRound(tester, puzzle);
      await _tapCell(tester, _outside(puzzle, flashPattern(puzzle, 0, 0)), 3);
      expect(_status(1, 1), findsOneWidget);
      // 对局中计时器每秒出帧，pumpAndSettle 等不到停：菜单开合只推进固定时长。
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('这一题从头来'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_start, findsOneWidget);
      expect(_status(1, 0), findsOneWidget);
      _expectBoard(3, _dark);
      // 等着的下一组不会再亮起来。
      await tester.pump(flashReveal + flashLead);
      _expectBoard(3, _dark);

      await tester.tap(_start);
      await tester.pump();
      await _showRound(tester, puzzle);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('换一道题'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_start, findsOneWidget);
      expect(_status(1, 0), findsOneWidget);
      await tester.pump(flashReveal + flashLead);
      _expectBoard(3, _dark);
      semantics.dispose();
    });

    testWidgets('6×6 在 360dp 宽、1.3 倍字号下放得下，每格触区不小于 48', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view
        ..physicalSize = const Size(1080, 1920)
        ..devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _open(tester, seed: 6, tier: PuzzleTier.expert);
      expect(tester.takeException(), isNull);
      for (var cell = 0; cell < 36; cell++) {
        final rect = tester.getRect(_cell(cell, 6));
        expect(rect.width, greaterThanOrEqualTo(48), reason: '$cell');
        expect(rect.height, greaterThanOrEqualTo(48), reason: '$cell');
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(360));
      }
      semantics.dispose();
    });
  });
}
