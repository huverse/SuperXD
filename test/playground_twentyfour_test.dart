import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/twentyfour/twentyfour_page.dart';
import 'package:superxd/playground/puzzle/twentyfour/twentyfour_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_theme.dart';

const _rules = TwentyFourRules();

TwentyFourValue _value(int numerator, [int denominator = 1]) => TwentyFourValue(numerator, denominator);
TwentyFourStep _step(int first, TwentyFourOp op, int second) => TwentyFourStep(first, op, second);
TwentyFourPuzzle _puzzle(List<int> numbers) => TwentyFourPuzzle(numbers);

// 每档的数的区间与难度分段（同 twentyfour_rules.dart 的 _ranges、_scores）。
const _ranges = {PuzzleTier.entry: (1, 9), PuzzleTier.easy: (1, 10), PuzzleTier.normal: (1, 13), PuzzleTier.hard: (1, 13), PuzzleTier.expert: (1, 13)};
const _scores = {PuzzleTier.entry: (1, 2), PuzzleTier.easy: (3, 4), PuzzleTier.normal: (5, 6), PuzzleTier.hard: (7, 8), PuzzleTier.expert: (9, 10)};

const _opIcons = {
  TwentyFourOp.add: CampusIcons.operatorAdd,
  TwentyFourOp.subtract: CampusIcons.operatorSubtract,
  TwentyFourOp.multiply: CampusIcons.operatorMultiply,
  TwentyFourOp.divide: CampusIcons.operatorDivide,
};

Finder _card(int slot) => find.byKey(ValueKey('twentyfour-card-$slot'));
Finder _key(TwentyFourOp op) => find.byIcon(_opIcons[op]!);
Finder _status(int left) => find.bySemanticsLabel(RegExp('· 剩 $left 张\$'));

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；点按后推进固定时长（合并的过渡 260ms）。
Future<void> _wait(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

// 点出一步合并：第一张、运算、第二张。
Future<void> _merge(WidgetTester tester, TwentyFourStep step) async {
  await tester.tap(_card(step.first));
  await _wait(tester);
  await tester.tap(_key(step.op));
  await _wait(tester);
  await tester.tap(_card(step.second));
  await _wait(tester);
}

Future<PlaygroundStore> _open(WidgetTester tester, {required int seed, PuzzleTier tier = PuzzleTier.entry}) async {
  final store = PlaygroundStore.memory();
  await store.chooseTier('twentyfour', tier);
  final game = playgroundCatalog.firstWhere((game) => game.id == 'twentyfour');
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: TwentyFourPage(game: game, store: store, seeds: () => seed)));
  await tester.pumpAndSettle();
  return store;
}

// 记下触感：选卡、选运算、合并是选择触感，不让做是重震。
List<String> _haptics(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') calls.add(call.arguments as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

void main() {
  group('24 点规则', () {
    test('有理数精确算：约到最简、分母为正，8 ÷ 3 × 3 正好回到 8，除以 0 没有结果', () {
      expect(_value(6, -4), _value(-3, 2));
      expect(_value(6, -4).toString(), '-3/2');
      expect(_value(0, -5), _value(0));
      expect(_value(48, 2).whole, isTrue);
      final third = TwentyFourOp.divide.apply(_value(8), _value(3))!;
      expect(third.toString(), '8/3');
      expect(third.whole, isFalse);
      expect(TwentyFourOp.multiply.apply(third, _value(3)), _value(8));
      expect(TwentyFourOp.subtract.apply(_value(3), third), _value(1, 3));
      expect(TwentyFourOp.add.apply(_value(1, 3), _value(2, 3)), _value(1));
      expect(TwentyFourOp.divide.apply(_value(8), _value(0)), isNull);
      expect(TwentyFourOp.coded(3), TwentyFourOp.divide);
      expect(TwentyFourOp.coded(4), isNull);
    });

    test('合并：结果放进第二张的位置、第一张的位置空出来；同一个位置、空了的位置、越界与除以 0 都不让合', () {
      final slots = twentyFourStart(_puzzle([3, 3, 8, 8]));
      expect(twentyFourMerge(slots, _step(2, TwentyFourOp.subtract, 0)), _value(5));
      expect(twentyFourMerge(slots, _step(0, TwentyFourOp.subtract, 2)), _value(-5));
      expect(twentyFourMerge(slots, _step(1, TwentyFourOp.add, 1)), isNull);
      expect(twentyFourMerge(slots, _step(4, TwentyFourOp.add, 1)), isNull);
      expect(twentyFourMerge(slots, _step(-1, TwentyFourOp.add, 1)), isNull);
      expect(twentyFourReplay(_puzzle([3, 3, 8, 8]), [_step(2, TwentyFourOp.add, 0)]), [_value(11), _value(3), null, _value(8)]);
      // 第一张已经合走，它的位置空了。
      expect(twentyFourReplay(_puzzle([3, 3, 8, 8]), [_step(2, TwentyFourOp.add, 0), _step(2, TwentyFourOp.add, 1)]), isNull);
      // 3 − 3 = 0，再拿 8 除以它。
      expect(twentyFourReplay(_puzzle([3, 3, 8, 8]), [_step(0, TwentyFourOp.subtract, 1), _step(2, TwentyFourOp.divide, 1)]), isNull);
    });

    test('分数的走法：3 3 8 8 是 8 ÷ (3 − 8 ÷ 3)，1 5 5 5 是 5 × (5 − 1 ÷ 5)，中间经过 8/3、1/3 与 1/5、24/5', () {
      final cards = _puzzle([3, 3, 8, 8]);
      final steps = [_step(2, TwentyFourOp.divide, 0), _step(1, TwentyFourOp.subtract, 0), _step(3, TwentyFourOp.divide, 0)];
      expect(twentyFourReplay(cards, steps.take(1)), [_value(8, 3), _value(3), null, _value(8)]);
      expect(twentyFourReplay(cards, steps.take(2)), [_value(1, 3), null, null, _value(8)]);
      expect(twentyFourReplay(cards, steps), [_value(24), null, null, null]);
      expect(_rules.solved(cards, steps), isTrue);
      final fives = [_step(0, TwentyFourOp.divide, 1), _step(2, TwentyFourOp.subtract, 1), _step(3, TwentyFourOp.multiply, 1)];
      expect(twentyFourReplay(_puzzle([1, 5, 5, 5]), fives.take(2))![1], _value(24, 5));
      expect(_rules.solved(_puzzle([1, 5, 5, 5]), fives), isTrue);
      for (final numbers in [
        [3, 3, 8, 8],
        [1, 5, 5, 5],
        [3, 3, 7, 7],
        [1, 3, 4, 6],
      ]) {
        final analysis = twentyFourAnalyze(numbers);
        expect((analysis.solutions, analysis.needsDivision, analysis.needsFraction), (1, true, true), reason: '$numbers');
        expect(_rules.solved(_puzzle(numbers), analysis.sample!), isTrue, reason: '$numbers');
        expect(_rules.difficulty(_puzzle(numbers)), 10, reason: '$numbers');
      }
    });

    test('解法数去掉交换律、结合律与正负号等价的写法；参考解优先取不经过分数的走法', () {
      // 1 × 2 × 3 × 4（4 × 3 × 2 ÷ 1 同它）、(1 + 2 + 3) × 4、(1 + 3) × (2 + 4)。
      expect(twentyFourAnalyze([1, 2, 3, 4]).solutions, 3);
      expect(twentyFourAnalyze([4, 3, 2, 1]).solutions, 3);
      // 6 + 6 + 6 + 6、6 × 6 − 6 − 6（6 × 6 − (6 + 6) 同它）。
      expect(twentyFourAnalyze([6, 6, 6, 6]).solutions, 2);
      // (5 − 1) × (7 − 1) 与 (1 − 5) × (1 − 7) 是同一种，另一种是 (5 + 7) × (1 + 1)。
      expect(twentyFourAnalyze([1, 1, 5, 7]).solutions, 2);
      // 8 ÷ (3 − 8 ÷ 3) 只有一种。
      expect(twentyFourAnalyze([3, 3, 8, 8]).solutions, 1);
      final none = twentyFourAnalyze([1, 1, 1, 1]);
      expect((none.solutions, none.sample), (0, null));
      // 1 1 6 8 只有 6 × 8 ÷ (1 + 1)：要除法，但不经过分数。
      final halves = twentyFourAnalyze([1, 1, 6, 8]);
      expect((halves.solutions, halves.needsDivision, halves.needsFraction), (1, true, false));
      final sample = halves.sample!;
      for (var count = 1; count <= sample.length; count++) {
        expect(twentyFourReplay(_puzzle([1, 1, 6, 8]), sample.take(count))!.nonNulls.every((value) => value.whole), isTrue);
      }
    });

    test('每档出 20 道：数在这一档的区间、参考解解得开、档位要求（入门只用加减乘也能解且解法多，困难要除法，专家要经过分数）；难度分同档最多差 1、档间不倒挂；出题快且可复现', () {
      final timings = <PuzzleTier, int>{};
      int? lowerTop;
      for (final tier in PuzzleTier.values) {
        final (low, high) = _ranges[tier]!;
        final (lowestScore, highestScore) = _scores[tier]!;
        final scores = <int>[];
        var slowest = 0;
        for (var seed = 0; seed < 20; seed++) {
          final watch = Stopwatch()..start();
          final draw = _rules.generate(seed, tier);
          slowest = math.max(slowest, watch.elapsedMilliseconds);
          final numbers = draw.puzzle.numbers;
          final reason = '$tier $seed $numbers';
          expect(numbers, hasLength(4), reason: reason);
          expect(numbers.every((number) => number >= low && number <= high), isTrue, reason: reason);
          expect(draw.solution, hasLength(3), reason: reason);
          expect(_rules.solved(draw.puzzle, draw.solution), isTrue, reason: reason);
          final analysis = twentyFourAnalyze(numbers);
          switch (tier) {
            case PuzzleTier.entry:
              expect(analysis.needsDivision, isFalse, reason: reason);
              expect(analysis.solutions, greaterThanOrEqualTo(5), reason: reason);
            case PuzzleTier.easy:
              expect(analysis.needsDivision, isFalse, reason: reason);
              expect(analysis.solutions, inInclusiveRange(3, 4), reason: reason);
            case PuzzleTier.normal:
              expect(analysis.needsDivision, isFalse, reason: reason);
              expect(analysis.solutions, inInclusiveRange(1, 2), reason: reason);
            case PuzzleTier.hard:
              expect((analysis.needsDivision, analysis.needsFraction), (true, false), reason: reason);
            case PuzzleTier.expert:
              expect(analysis.needsFraction, isTrue, reason: reason);
          }
          scores.add(_rules.difficulty(draw.puzzle));
        }
        timings[tier] = slowest;
        final lowest = scores.reduce(math.min), highest = scores.reduce(math.max);
        expect(lowest, greaterThanOrEqualTo(lowestScore), reason: '$tier $scores');
        expect(highest, lessThanOrEqualTo(highestScore), reason: '$tier $scores');
        expect(highest - lowest, lessThanOrEqualTo(1), reason: '$tier $scores');
        if (lowerTop != null) expect(lowest, greaterThan(lowerTop), reason: '$tier 要高过下一档');
        lowerTop = highest;
      }
      // 对局页同步出题：专家档平均抽百来次才中，单题最慢也要在 300ms 以内（本机 JIT 实测最慢约 50ms）。
      for (final MapEntry(key: tier, value: slowest) in timings.entries) {
        expect(slowest, lessThan(300), reason: '$tier 单题最慢 ${slowest}ms');
      }
      expect(_rules.generate(7, PuzzleTier.hard).puzzle.numbers, _rules.generate(7, PuzzleTier.hard).puzzle.numbers);
      expect(_rules.generate(7, PuzzleTier.normal).puzzle.numbers, isNot(_rules.generate(8, PuzzleTier.normal).puzzle.numbers));
    });

    test('按规则重放判定，不和参考解比：另一种解法也算；数没用全、同一张用两次、空了的位置、除以 0、结果不是 24、多走一步都不算', () {
      final cards = _puzzle([1, 2, 3, 4]);
      // (1 + 2 + 3) × 4 与 1 × 2 × 3 × 4。
      expect(_rules.solved(cards, [_step(0, TwentyFourOp.add, 1), _step(1, TwentyFourOp.add, 2), _step(2, TwentyFourOp.multiply, 3)]), isTrue);
      expect(_rules.solved(cards, [_step(0, TwentyFourOp.multiply, 1), _step(1, TwentyFourOp.multiply, 2), _step(2, TwentyFourOp.multiply, 3)]), isTrue);
      // 只合两步：剩两张没用全（2 × 3 = 6、6 × 4 = 24，1 没用上）。
      expect(_rules.solved(cards, [_step(1, TwentyFourOp.multiply, 2), _step(2, TwentyFourOp.multiply, 3)]), isFalse);
      // 第一步把 2 合走了，第二步又拿它的位置。
      expect(_rules.solved(cards, [_step(1, TwentyFourOp.multiply, 2), _step(1, TwentyFourOp.multiply, 3), _step(0, TwentyFourOp.multiply, 3)]), isFalse);
      expect(_rules.solved(cards, [_step(2, TwentyFourOp.multiply, 2), _step(1, TwentyFourOp.multiply, 3), _step(0, TwentyFourOp.multiply, 3)]), isFalse);
      // 1 + 2 + 3 + 4 = 10。
      expect(_rules.solved(cards, [_step(0, TwentyFourOp.add, 1), _step(1, TwentyFourOp.add, 2), _step(2, TwentyFourOp.add, 3)]), isFalse);
      // 3 3 8 8：3 − 3 = 0，8 ÷ 0 不让合。
      expect(_rules.solved(_puzzle([3, 3, 8, 8]), [_step(0, TwentyFourOp.subtract, 1), _step(2, TwentyFourOp.divide, 1), _step(1, TwentyFourOp.add, 3)]), isFalse);
      final steps = [_step(0, TwentyFourOp.multiply, 1), _step(1, TwentyFourOp.multiply, 2), _step(2, TwentyFourOp.multiply, 3)];
      expect(_rules.solved(cards, [...steps, _step(3, TwentyFourOp.multiply, 0)]), isFalse);
      expect(_rules.solved(cards, [_step(0, TwentyFourOp.multiply, 4), ...steps.skip(1)]), isFalse);
    });

    test('编解码往返，坏输入抛 FormatException', () {
      for (final tier in PuzzleTier.values) {
        final draw = _rules.generate(9, tier);
        final json = jsonDecode(jsonEncode(_rules.encodePuzzle(draw.puzzle)));
        expect(json, draw.puzzle.numbers);
        final puzzle = _rules.decodePuzzle(json);
        expect(puzzle.numbers, draw.puzzle.numbers);
        final answer = _rules.decodeAnswer(jsonDecode(jsonEncode(_rules.encodeAnswer(draw.solution))));
        expect(_rules.solved(puzzle, answer), isTrue);
        expect(_rules.encodeAnswer(answer), _rules.encodeAnswer(draw.solution));
      }
      expect(_rules.encodeAnswer([_step(2, TwentyFourOp.divide, 0)]), [
        [2, 3, 0],
      ]);
      expect(_rules.decodePuzzle([3, 3, 8, 8]).numbers, [3, 3, 8, 8]);
      for (final bad in <Object?>[
        null,
        '3,3,8,8',
        {'numbers': [3, 3, 8, 8]},
        [3, 3, 8],
        [3, 3, 8, 8, 1],
        [0, 3, 8, 8],
        [3, 3, 8, 14],
        [3, 3, 8, '8'],
        [3, 3, 8, 8.5],
        // 算不出 24。
        [1, 1, 1, 1],
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      expect(_rules.decodeAnswer(const []), isEmpty);
      for (final bad in <Object?>[
        null,
        '[[2,3,0]]',
        [2, 3, 0],
        [
          [2, 3],
        ],
        [
          [2, 3, 0, 1],
        ],
        [
          [2, 4, 0],
        ],
        [
          [4, 3, 0],
        ],
        [
          [2, 3, -1],
        ],
        [
          [2, 3, 0.5],
        ],
        List.filled(4, [0, 0, 1]),
      ]) {
        expect(() => _rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('登记在数字计算、能进挑战；一句话玩法十个字以内', () {
      final game = playgroundCatalog.firstWhere((game) => game.id == 'twentyfour');
      expect(game.name, '24 点');
      expect(game.group, numberGroup);
      expect(game.challengeable, isTrue);
      expect(game.icon, CampusIcons.twentyfour);
      expect(game.summary.length, lessThanOrEqualTo(10));
    });
  });

  group('24 点对局页', () {
    testWidgets('点卡、运算、再点卡合成新卡（读屏读出数与选中），算式行写出来；按参考解合到 24 先鼓一下再弹新纪录，可换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      final store = await _open(tester, seed: 3);
      final draw = _rules.generate(3, PuzzleTier.entry);
      final numbers = draw.puzzle.numbers;
      expect(_status(4), findsOneWidget);
      for (var slot = 0; slot < 4; slot++) {
        expect(tester.getSemantics(_card(slot)), isSemantics(label: '${numbers[slot]}', isButton: true, isSelected: false));
      }
      // 四个运算键读出名字，触区至少 48。
      for (final (op, name) in [(TwentyFourOp.add, '加'), (TwentyFourOp.subtract, '减'), (TwentyFourOp.multiply, '乘'), (TwentyFourOp.divide, '除')]) {
        expect(tester.getSemantics(_key(op)), isSemantics(label: name, isButton: true, isSelected: false, isEnabled: true));
        expect(tester.getSize(find.bySemanticsLabel(name)).height, greaterThanOrEqualTo(48));
      }
      expect(tester.getSize(_card(0)).height, greaterThanOrEqualTo(48));
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销')).onPressed, isNull);

      // 点第一张：选中；再点一次取消；先选运算再选卡也行。
      final first = draw.solution.first;
      await tester.tap(_card(first.first));
      await _wait(tester);
      expect(tester.getSemantics(_card(first.first)), isSemantics(label: '${numbers[first.first]}', isButton: true, isSelected: true));
      await tester.tap(_card(first.first));
      await _wait(tester);
      expect(tester.getSemantics(_card(first.first)), isSemantics(isSelected: false));
      await tester.tap(_key(first.op));
      await _wait(tester);
      expect(tester.getSemantics(_key(first.op)), isSemantics(isSelected: true));
      await tester.tap(_card(first.first));
      await _wait(tester);
      expect(haptics, everyElement('HapticFeedbackType.selectionClick'));
      await tester.tap(_card(first.second));
      await tester.pump();
      // 合并的过渡中途：第一张正滑向第二张、新卡正在淡入，两个位置画的都是过渡（不接点按），走完新卡才落到第二张的位置上。
      await tester.pump(const Duration(milliseconds: 100));
      expect(_card(first.second), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      final merged = twentyFourReplay(draw.puzzle, [first])!;
      expect(_status(3), findsOneWidget);
      expect(_card(first.first), findsNothing);
      expect(tester.getSemantics(_card(first.second)), isSemantics(label: twentyFourReading(merged[first.second]!), isSelected: false));
      expect(find.text('${numbers[first.first]} ${first.op.symbol} ${numbers[first.second]} = ${twentyFourText(merged[first.second]!)}'), findsOneWidget);
      expect(tester.getSemantics(_key(first.op)), isSemantics(isSelected: false));

      for (final step in draw.solution.skip(1)) {
        await _merge(tester, step);
      }
      expect(_status(1), findsOneWidget);
      // 解开后先放收尾（那张卡鼓一下），走完才弹结果。
      final last = draw.solution.last.second;
      final rest = tester.getSize(_card(last)).width;
      var widest = rest;
      for (var frame = 0; frame < 30 && find.text('新纪录').evaluate().isEmpty; frame++) {
        widest = math.max(widest, tester.getRect(_card(last)).width);
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(widest, greaterThan(rest * 1.02));
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('= 24'), findsWidgets);
      expect(store.best('twentyfour', PuzzleTier.entry), isNotNull);

      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      expect(store.tierOf('twentyfour'), PuzzleTier.easy);
      expect(_status(4), findsOneWidget);
      expect(tester.getSemantics(_card(0)), isSemantics(label: '${_rules.generate(3, PuzzleTier.easy).puzzle.numbers[0]}'));
      semantics.dispose();
    });

    testWidgets('除以 0 不让合：重震、提示原因，卡不变、第一张与运算仍选着；接着点另一张合出 8/5，读屏念「5分之8」', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      // 入门第 1 题是 8 4 5 4：4 − 4 = 0。
      await _open(tester, seed: 1);
      expect(_rules.generate(1, PuzzleTier.entry).puzzle.numbers, [8, 4, 5, 4]);
      await _merge(tester, _step(1, TwentyFourOp.subtract, 3));
      expect(tester.getSemantics(_card(3)), isSemantics(label: '0'));
      haptics.clear();
      await _merge(tester, _step(0, TwentyFourOp.divide, 3));
      expect(haptics.last, 'HapticFeedbackType.heavyImpact');
      expect(find.text('不能除以 0'), findsOneWidget);
      expect(_status(3), findsOneWidget);
      expect(tester.getSemantics(_card(0)), isSemantics(label: '8', isSelected: true));
      expect(tester.getSemantics(_card(3)), isSemantics(label: '0'));
      expect(tester.getSemantics(_key(TwentyFourOp.divide)), isSemantics(isSelected: true));

      // 第一张与「除」还选着，直接点 5：8 ÷ 5 = 8/5（合了一步正常的，提示收起）。
      await tester.tap(_card(2));
      await _wait(tester);
      // 提示条收拢完拿掉条目，要再出一帧。
      await tester.pump();
      expect(find.text('不能除以 0'), findsNothing);
      expect(tester.getSemantics(_card(2)), isSemantics(label: '5分之8'));
      expect(find.text('8 ÷ 5 = 8/5'), findsOneWidget);
      expect(_status(2), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('剩一张不是 24：重震、提示得数、描警示边并读出「不是 24」，不弹结果；按步撤销退回原来的两张', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      // 入门第 0 题是 8 6 2 5：全加起来是 21。
      await _open(tester, seed: 0);
      expect(_rules.generate(0, PuzzleTier.entry).puzzle.numbers, [8, 6, 2, 5]);
      await _merge(tester, _step(0, TwentyFourOp.add, 1));
      await _merge(tester, _step(1, TwentyFourOp.add, 2));
      expect(find.text('8 + 6 + 2 = 16'), findsOneWidget);
      haptics.clear();
      await _merge(tester, _step(2, TwentyFourOp.add, 3));
      expect(haptics.last, 'HapticFeedbackType.heavyImpact');
      expect(find.text('得数是 21，不是 24'), findsOneWidget);
      expect(tester.getSemantics(_card(3)), isSemantics(label: '21，不是 24'));
      expect(_status(1), findsOneWidget);
      // 合并的过渡走完再晃一下，晃完回原位；不弹结果。
      final rest = tester.getRect(_card(3)).left;
      var farthest = 0.0;
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        farthest = math.max(farthest, (tester.getRect(_card(3)).left - rest).abs());
      }
      expect(farthest, greaterThan(2));
      await _wait(tester);
      expect(tester.getRect(_card(3)).left, closeTo(rest, .01));
      expect(find.text('新纪录'), findsNothing);
      expect(tester.getSemantics(_key(TwentyFourOp.add)), isSemantics(isEnabled: false));

      // 撤销一步：16 与 5 回来，提示收起；再撤销一步：14、2 与 5。
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _wait(tester);
      await tester.pump();
      expect(find.text('得数是 21，不是 24'), findsNothing);
      expect(_status(2), findsOneWidget);
      expect(tester.getSemantics(_card(2)), isSemantics(label: '16'));
      expect(tester.getSemantics(_card(3)), isSemantics(label: '5'));
      expect(find.text('8 + 6 + 2 = 16'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _wait(tester);
      expect(_status(3), findsOneWidget);
      expect(tester.getSemantics(_card(1)), isSemantics(label: '14'));
      expect(tester.getSemantics(_card(2)), isSemantics(label: '2'));
      expect(find.text('8 + 6 = 14'), findsOneWidget);

      // 从头来：四张回到开局。
      await tester.tap(find.byTooltip('更多操作'));
      await _wait(tester);
      await tester.tap(find.text('这一题从头来'));
      await _wait(tester);
      expect(_status(4), findsOneWidget);
      expect(tester.getSemantics(_card(0)), isSemantics(label: '8'));
      semantics.dispose();
    });

    testWidgets('减少动画：合并直接到位，解开不放收尾直接弹结果', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _open(tester, seed: 5);
      final draw = _rules.generate(5, PuzzleTier.entry);
      final first = draw.solution.first;
      await tester.tap(_card(first.first));
      await tester.pump();
      await tester.tap(_key(first.op));
      await tester.pump();
      await tester.tap(_card(first.second));
      await tester.pump();
      expect(_card(first.first), findsNothing);
      expect(_status(3), findsOneWidget);
      for (final step in draw.solution.skip(1)) {
        await tester.tap(_card(step.first));
        await tester.pump();
        await tester.tap(_key(step.op));
        await tester.pump();
        await tester.tap(_card(step.second));
        await tester.pump();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });
  });
}
