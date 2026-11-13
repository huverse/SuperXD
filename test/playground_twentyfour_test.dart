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
TwentyFourPuzzle _puzzle(List<int> numbers, [Set<TwentyFourOp> ops = twentyFourClassic]) => TwentyFourPuzzle(numbers, ops);

const _add = TwentyFourOp.add, _subtract = TwentyFourOp.subtract, _multiply = TwentyFourOp.multiply, _divide = TwentyFourOp.divide;
const _power = TwentyFourOp.power, _root = TwentyFourOp.root;

// 每档的数的区间与难度分段（同 twentyfour_rules.dart 的 _ranges、_scores）。
const _ranges = {PuzzleTier.entry: (1, 9), PuzzleTier.easy: (1, 10), PuzzleTier.normal: (1, 13), PuzzleTier.hard: (1, 13), PuzzleTier.expert: (1, 13)};
const _scores = {PuzzleTier.entry: (1, 2), PuzzleTier.easy: (3, 4), PuzzleTier.normal: (5, 6), PuzzleTier.hard: (7, 8), PuzzleTier.expert: (9, 10)};

const _opIcons = {
  TwentyFourOp.add: CampusIcons.operatorAdd,
  TwentyFourOp.subtract: CampusIcons.operatorSubtract,
  TwentyFourOp.multiply: CampusIcons.operatorMultiply,
  TwentyFourOp.divide: CampusIcons.operatorDivide,
  TwentyFourOp.power: CampusIcons.operatorPower,
  TwentyFourOp.root: CampusIcons.operatorRoot,
};
const _opNames = {_add: '加', _subtract: '减', _multiply: '乘', _divide: '除', _power: '乘方', _root: '开方'};

Finder _card(int slot) => find.byKey(ValueKey('twentyfour-card-$slot'));
Finder _key(TwentyFourOp op) => find.byIcon(_opIcons[op]!);
Finder _status(int left) => find.bySemanticsLabel(RegExp('· 剩 $left 张\$'));

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；点按后推进固定时长（合并的过渡 260ms）。
Future<void> _wait(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

// 在页面上点出一步：picked 是现在选着的卡（开方后那张仍选着，不用再点）；返回做完以后选着的卡。
// 二元：第一张、运算、第二张；开方：那张卡、开方键（有选着的卡时开方直接作用在它上面）。
Future<int?> _play(WidgetTester tester, TwentyFourStep step, [int? picked]) async {
  if (picked != step.first) {
    await tester.tap(_card(step.first));
    await _wait(tester);
  }
  await tester.tap(_key(step.op));
  await _wait(tester);
  if (step.op.unary) return step.first;
  await tester.tap(_card(step.second));
  await _wait(tester);
  return null;
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
      final third = _divide.apply(_value(8), _value(3))!;
      expect(third.toString(), '8/3');
      expect(third.whole, isFalse);
      expect(_multiply.apply(third, _value(3)), _value(8));
      expect(_subtract.apply(_value(3), third), _value(1, 3));
      expect(_add.apply(_value(1, 3), _value(2, 3)), _value(1));
      expect(_divide.apply(_value(8), _value(0)), isNull);
      expect(TwentyFourOp.coded(3), _divide);
      expect(TwentyFourOp.coded(4), _power);
      expect(TwentyFourOp.coded(5), _root);
      expect(TwentyFourOp.coded(6), isNull);
    });

    test('乘方：指数要是整数、绝对值不超过 10，0 的 0 次与负数次方不行，结果（约分后）超过一百万不行；其余运算也受这个上限管', () {
      TwentyFourValue? power(TwentyFourValue base, TwentyFourValue exponent) => _power.apply(base, exponent);
      expect(power(_value(2), _value(3)), _value(8));
      expect(power(_value(2), _value(-2)), _value(1, 4));
      expect(power(_value(-2, 3), _value(3)), _value(-8, 27));
      expect(power(_value(-2), _value(-3)), _value(-1, 8));
      expect(power(_value(5), _value(0)), _value(1));
      expect(power(_value(0), _value(3)), _value(0));
      expect(power(_value(0), _value(0)), isNull);
      expect(power(_value(0), _value(-1)), isNull);
      // 指数不是整数（4 的二分之一次方要用开方）。
      expect(power(_value(4), _value(1, 2)), isNull);
      expect(power(_value(1), _value(twentyFourMaxExponent)), _value(1));
      expect(power(_value(1), _value(twentyFourMaxExponent + 1)), isNull);
      expect(power(_value(1), _value(-twentyFourMaxExponent - 1)), isNull);
      expect(power(_value(10), _value(6)), _value(twentyFourLimit));
      expect(power(_value(13), _value(6)), isNull);
      expect(power(_value(1, 1000), _value(2)), _value(1, twentyFourLimit));
      expect(power(_value(1, 1000), _value(3)), isNull);
      expect(_multiply.apply(_value(1000), _value(1000)), _value(twentyFourLimit));
      expect(_multiply.apply(_value(1000), _value(1001)), isNull);
      expect(_subtract.apply(_value(-1), _value(twentyFourLimit)), isNull);
    });

    test('开方：只在开得尽时可用（约分后分子分母都是完全平方数），负数、0、1 不让开；一元，结果留在原位置', () {
      expect(_value(9).root(), _value(3));
      expect(_value(4, 9).root(), _value(2, 3));
      expect(_value(1, 4).root(), _value(1, 2));
      expect(_value(8, 2).root(), _value(2));
      expect(_value(8).root(), isNull);
      expect(_value(2, 9).root(), isNull);
      expect(_value(-4).root(), isNull);
      expect(_value(0).root(), isNull);
      expect(_value(1).root(), isNull);
      expect(_root.apply(_value(9), _value(9)), isNull);
      final puzzle = _puzzle([9, 8, 1, 1], twentyFourExtended);
      final slots = twentyFourStart(puzzle);
      expect(twentyFourMerge(slots, _step(0, _root, 0)), _value(3));
      expect(twentyFourMerge(slots, _step(0, _root, 1)), isNull);
      expect(twentyFourMerge(slots, _step(1, _root, 1)), isNull);
      expect(twentyFourMerge(slots, _step(2, _root, 2)), isNull);
      expect(twentyFourMerge(slots, _step(0, _power, 0)), isNull);
      expect(twentyFourReplay(puzzle, [_step(0, _root, 0)]), [_value(3), _value(8), _value(1), _value(1)]);
      // √9 × 8 × 1 × 1。
      expect(_rules.solved(puzzle, [_step(0, _root, 0), _step(1, _multiply, 0), _step(2, _multiply, 3), _step(3, _multiply, 0)]), isTrue);
    });

    test('题面只允许经典四则时不能用乘方与开方：同样的走法在入门到普通不算；每档出的题写明允许的运算', () {
      final rooted = [_step(0, _root, 0), _step(1, _multiply, 0), _step(2, _multiply, 3), _step(3, _multiply, 0)];
      expect(twentyFourReplay(_puzzle([9, 8, 1, 1]), [_step(0, _root, 0)]), isNull);
      expect(_rules.solved(_puzzle([9, 8, 1, 1]), rooted), isFalse);
      // 2^3 × 3 × 1。
      final powered = [_step(0, _power, 1), _step(1, _multiply, 2), _step(3, _multiply, 2)];
      expect(_rules.solved(_puzzle([2, 3, 3, 1], twentyFourExtended), powered), isTrue);
      expect(_rules.solved(_puzzle([2, 3, 3, 1]), powered), isFalse);
      // 只加了乘方、没加开方的题面：开方不算。
      expect(_rules.solved(_puzzle([9, 8, 1, 1], {...twentyFourClassic, _power}), rooted), isFalse);
      for (final tier in PuzzleTier.values) {
        expect(_rules.generate(0, tier).puzzle.ops, tier.index >= PuzzleTier.hard.index ? twentyFourExtended : twentyFourClassic, reason: '$tier');
      }
    });

    test('合并：结果放进第二张的位置、第一张的位置空出来；同一个位置、空了的位置、越界与除以 0 都不让合', () {
      final slots = twentyFourStart(_puzzle([3, 3, 8, 8]));
      expect(twentyFourMerge(slots, _step(2, _subtract, 0)), _value(5));
      expect(twentyFourMerge(slots, _step(0, _subtract, 2)), _value(-5));
      expect(twentyFourMerge(slots, _step(1, _add, 1)), isNull);
      expect(twentyFourMerge(slots, _step(4, _add, 1)), isNull);
      expect(twentyFourMerge(slots, _step(-1, _add, 1)), isNull);
      expect(twentyFourReplay(_puzzle([3, 3, 8, 8]), [_step(2, _add, 0)]), [_value(11), _value(3), null, _value(8)]);
      // 第一张已经合走，它的位置空了。
      expect(twentyFourReplay(_puzzle([3, 3, 8, 8]), [_step(2, _add, 0), _step(2, _add, 1)]), isNull);
      // 3 − 3 = 0，再拿 8 除以它。
      expect(twentyFourReplay(_puzzle([3, 3, 8, 8]), [_step(0, _subtract, 1), _step(2, _divide, 1)]), isNull);
    });

    test('分数的走法：3 3 8 8 是 8 ÷ (3 − 8 ÷ 3)，1 5 5 5 是 5 × (5 − 1 ÷ 5)，中间经过 8/3、1/3 与 1/5、24/5', () {
      final cards = _puzzle([3, 3, 8, 8]);
      final steps = [_step(2, _divide, 0), _step(1, _subtract, 0), _step(3, _divide, 0)];
      expect(twentyFourReplay(cards, steps.take(1)), [_value(8, 3), _value(3), null, _value(8)]);
      expect(twentyFourReplay(cards, steps.take(2)), [_value(1, 3), null, null, _value(8)]);
      expect(twentyFourReplay(cards, steps), [_value(24), null, null, null]);
      expect(_rules.solved(cards, steps), isTrue);
      final fives = [_step(0, _divide, 1), _step(2, _subtract, 1), _step(3, _multiply, 1)];
      expect(twentyFourReplay(_puzzle([1, 5, 5, 5]), fives.take(2))![1], _value(24, 5));
      expect(_rules.solved(_puzzle([1, 5, 5, 5]), fives), isTrue);
      for (final numbers in [
        [3, 3, 8, 8],
        [1, 5, 5, 5],
        [3, 3, 7, 7],
        [1, 3, 4, 6],
      ]) {
        final analysis = twentyFourAnalyze(numbers, twentyFourClassic);
        expect((analysis.solutions, analysis.plain, analysis.whole), (1, false, false), reason: '$numbers');
        expect(_rules.solved(_puzzle(numbers), analysis.sample!), isTrue, reason: '$numbers');
        expect(_rules.difficulty(_puzzle(numbers)), 10, reason: '$numbers');
      }
    });

    test('解法数去掉交换律、结合律与正负号等价的写法；参考解优先取不经过分数的走法', () {
      // 1 × 2 × 3 × 4（4 × 3 × 2 ÷ 1 同它）、(1 + 2 + 3) × 4、(1 + 3) × (2 + 4)。
      expect(twentyFourAnalyze([1, 2, 3, 4], twentyFourClassic).solutions, 3);
      expect(twentyFourAnalyze([4, 3, 2, 1], twentyFourClassic).solutions, 3);
      // 6 + 6 + 6 + 6、6 × 6 − 6 − 6（6 × 6 − (6 + 6) 同它）。
      expect(twentyFourAnalyze([6, 6, 6, 6], twentyFourClassic).solutions, 2);
      // (5 − 1) × (7 − 1) 与 (1 − 5) × (1 − 7) 是同一种，另一种是 (5 + 7) × (1 + 1)。
      expect(twentyFourAnalyze([1, 1, 5, 7], twentyFourClassic).solutions, 2);
      // 8 ÷ (3 − 8 ÷ 3) 只有一种。
      expect(twentyFourAnalyze([3, 3, 8, 8], twentyFourClassic).solutions, 1);
      final none = twentyFourAnalyze([1, 1, 1, 1], twentyFourExtended);
      expect((none.solutions, none.sample), (0, null));
      // 1 1 6 8 只有 6 × 8 ÷ (1 + 1)：要除法，但不经过分数。
      final halves = twentyFourAnalyze([1, 1, 6, 8], twentyFourClassic);
      expect((halves.solutions, halves.plain, halves.whole), (1, false, true));
      final sample = halves.sample!;
      for (var count = 1; count <= sample.length; count++) {
        expect(twentyFourReplay(_puzzle([1, 1, 6, 8]), sample.take(count))!.nonNulls.every((value) => value.whole), isTrue);
      }
    });

    test('乘方、开方的解法数：各当一个整体，指数等于 1 的乘方同乘以那个指数；只靠乘方或开方才解得开的算专家', () {
      // 2 2 2 3：2 × 2 × 2 × 3、(2 + 2) × 2 × 3，加上乘方多一种 2^2 × 2 × 3。
      expect(twentyFourAnalyze([2, 2, 2, 3], twentyFourClassic).solutions, 2);
      expect(twentyFourAnalyze([2, 2, 2, 3], twentyFourExtended).solutions, 3);
      // 1 1 5 5：经典四种（5 × 5 − 1 × 1、(1 + 5) × (5 − 1)、1 × 5 × 5 − 1、1 × (5 × 5 − 1)），加上 √(5^(5 − 1)) − 1 与 5^√(5 − 1) − 1；
      // 5 × 5^1 − 1、5 × 5^(1 × 1) − 1 这类指数等于 1 的写法同 1 × 5 × 5 − 1，不另算。
      expect(twentyFourAnalyze([1, 1, 5, 5], twentyFourClassic).solutions, 4);
      expect(twentyFourAnalyze([1, 1, 5, 5], twentyFourExtended).solutions, 6);
      // 1 1 1 5 经典四则算不出，加上乘方只有 5^(1 + 1) − 1；1 1 3 3 只有 3 × (1 + 1)^3。
      expect(twentyFourAnalyze([1, 1, 1, 5], twentyFourClassic).solutions, 0);
      final fives = twentyFourAnalyze([1, 1, 1, 5], twentyFourExtended);
      expect((fives.solutions, fives.plain, fives.whole), (1, false, false));
      expect(_rules.solved(_puzzle([1, 1, 1, 5], twentyFourExtended), fives.sample!), isTrue);
      expect(_rules.difficulty(_puzzle([1, 1, 1, 5], twentyFourExtended)), 10);
      expect(twentyFourAnalyze([1, 1, 3, 3], twentyFourExtended).solutions, 1);
      // 困难档的题加上乘方与开方：仍要除法、有整数走法，难度分仍在 7–8。
      final halves = twentyFourAnalyze([1, 1, 6, 8], twentyFourExtended);
      expect((halves.plain, halves.whole), (false, true));
      expect(_rules.difficulty(_puzzle([1, 1, 6, 8], twentyFourExtended)), inInclusiveRange(7, 8));
    });

    test('1–13 的 1820 组数：困难档能出 183 组，加上乘方与开方经典四则不经过分数解不开的有 358 组，专家档只取解法不超过 2 种的 107 组（原来只靠分数的 16 组）', () {
      var hard = 0, fractionOnly = 0, extendedOnly = 0, expert = 0;
      for (var a = 1; a <= 13; a++) {
        for (var b = a; b <= 13; b++) {
          for (var c = b; c <= 13; c++) {
            for (var d = c; d <= 13; d++) {
              final classic = twentyFourAnalyze([a, b, c, d], twentyFourClassic);
              if (classic.whole) {
                if (!classic.plain) hard++;
                continue;
              }
              if (classic.solutions > 0) fractionOnly++;
              final extended = twentyFourAnalyze([a, b, c, d], twentyFourExtended).solutions;
              if (extended > 0) extendedOnly++;
              if (extended > 0 && extended <= twentyFourExpertSolutions) expert++;
            }
          }
        }
      }
      expect([hard, fractionOnly, extendedOnly, expert], [183, 16, 358, 107]);
    });

    test('每档出 20 道：数在这一档的区间、参考解解得开、档位要求（入门只用加减乘也能解且解法多，困难要除法，专家要用到乘方、开方或分数）；难度分同档最多差 1、档间不倒挂；出题快且可复现', () {
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
          expect(draw.solution.length, inInclusiveRange(3, twentyFourMaxSteps), reason: reason);
          expect(_rules.solved(draw.puzzle, draw.solution), isTrue, reason: reason);
          final classic = twentyFourAnalyze(numbers, twentyFourClassic);
          switch (tier) {
            case PuzzleTier.entry:
              expect(classic.plain, isTrue, reason: reason);
              expect(classic.solutions, greaterThanOrEqualTo(5), reason: reason);
            case PuzzleTier.easy:
              expect(classic.plain, isTrue, reason: reason);
              expect(classic.solutions, inInclusiveRange(3, 4), reason: reason);
            case PuzzleTier.normal:
              expect(classic.plain, isTrue, reason: reason);
              expect(classic.solutions, inInclusiveRange(1, 2), reason: reason);
            case PuzzleTier.hard:
              expect((classic.plain, classic.whole), (false, true), reason: reason);
            case PuzzleTier.expert:
              expect(classic.whole, isFalse, reason: reason);
              expect(twentyFourAnalyze(numbers, twentyFourExtended).solutions, inInclusiveRange(1, twentyFourExpertSolutions), reason: reason);
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
      // 对局页同步出题：单题最慢也要在 300ms 以内（本机 JIT 实测各档最慢约 12ms）。
      for (final MapEntry(key: tier, value: slowest) in timings.entries) {
        expect(slowest, lessThan(300), reason: '$tier 单题最慢 ${slowest}ms');
      }
      expect(_rules.generate(7, PuzzleTier.hard).puzzle.numbers, _rules.generate(7, PuzzleTier.hard).puzzle.numbers);
      expect(_rules.generate(7, PuzzleTier.expert).puzzle.numbers, _rules.generate(7, PuzzleTier.expert).puzzle.numbers);
      expect(_rules.generate(7, PuzzleTier.normal).puzzle.numbers, isNot(_rules.generate(8, PuzzleTier.normal).puzzle.numbers));
    });

    test('按规则重放判定，不和参考解比：另一种解法也算；数没用全、同一张用两次、空了的位置、除以 0、结果不是 24、多走一步都不算', () {
      final cards = _puzzle([1, 2, 3, 4]);
      // (1 + 2 + 3) × 4 与 1 × 2 × 3 × 4。
      expect(_rules.solved(cards, [_step(0, _add, 1), _step(1, _add, 2), _step(2, _multiply, 3)]), isTrue);
      expect(_rules.solved(cards, [_step(0, _multiply, 1), _step(1, _multiply, 2), _step(2, _multiply, 3)]), isTrue);
      // 只合两步：剩两张没用全（2 × 3 = 6、6 × 4 = 24，1 没用上）。
      expect(_rules.solved(cards, [_step(1, _multiply, 2), _step(2, _multiply, 3)]), isFalse);
      // 第一步把 2 合走了，第二步又拿它的位置。
      expect(_rules.solved(cards, [_step(1, _multiply, 2), _step(1, _multiply, 3), _step(0, _multiply, 3)]), isFalse);
      expect(_rules.solved(cards, [_step(2, _multiply, 2), _step(1, _multiply, 3), _step(0, _multiply, 3)]), isFalse);
      // 1 + 2 + 3 + 4 = 10。
      expect(_rules.solved(cards, [_step(0, _add, 1), _step(1, _add, 2), _step(2, _add, 3)]), isFalse);
      // 3 3 8 8：3 − 3 = 0，8 ÷ 0 不让合。
      expect(_rules.solved(_puzzle([3, 3, 8, 8]), [_step(0, _subtract, 1), _step(2, _divide, 1), _step(1, _add, 3)]), isFalse);
      final steps = [_step(0, _multiply, 1), _step(1, _multiply, 2), _step(2, _multiply, 3)];
      expect(_rules.solved(cards, [...steps, _step(3, _multiply, 0)]), isFalse);
      expect(_rules.solved(cards, [_step(0, _multiply, 4), ...steps.skip(1)]), isFalse);
    });

    test('编解码往返（题面带允许的运算，开方写成 [卡, 5, 同一张卡]），坏输入抛 FormatException', () {
      for (final tier in PuzzleTier.values) {
        final draw = _rules.generate(9, tier);
        final json = jsonDecode(jsonEncode(_rules.encodePuzzle(draw.puzzle)));
        expect(json, {'numbers': draw.puzzle.numbers, 'ops': [for (final op in draw.puzzle.ops) op.code]..sort()});
        final puzzle = _rules.decodePuzzle(json);
        expect(puzzle.numbers, draw.puzzle.numbers);
        expect(puzzle.ops, draw.puzzle.ops);
        final answer = _rules.decodeAnswer(jsonDecode(jsonEncode(_rules.encodeAnswer(draw.solution))));
        expect(_rules.solved(puzzle, answer), isTrue);
        expect(_rules.encodeAnswer(answer), _rules.encodeAnswer(draw.solution));
      }
      expect(_rules.encodeAnswer([_step(2, _divide, 0), _step(1, _root, 1)]), [
        [2, 3, 0],
        [1, 5, 1],
      ]);
      final rootStep = _rules.decodeAnswer([
        [1, 5, 1],
      ]).single;
      expect((rootStep.first, rootStep.op, rootStep.second), (1, _root, 1));
      expect(_rules.decodePuzzle({'numbers': [3, 3, 8, 8], 'ops': [0, 1, 2, 3]}).ops, twentyFourClassic);
      // 1 1 1 5 只有加上乘方才解得开：经典四则的题面拒收，带乘方开方的收。
      expect(_rules.decodePuzzle({'numbers': [1, 1, 1, 5], 'ops': [0, 1, 2, 3, 4, 5]}).ops, twentyFourExtended);
      for (final bad in <Object?>[
        null,
        [3, 3, 8, 8],
        {'numbers': [3, 3, 8, 8]},
        {'numbers': [3, 3, 8, 8], 'ops': null},
        {'numbers': [3, 3, 8, 8], 'ops': [0, 1, 2]},
        {'numbers': [3, 3, 8, 8], 'ops': [0, 1, 2, 3, 3]},
        {'numbers': [3, 3, 8, 8], 'ops': [0, 1, 2, 3, 6]},
        {'numbers': [3, 3, 8, 8], 'ops': [0, 1, 2, '3']},
        {'numbers': [3, 3, 8], 'ops': [0, 1, 2, 3]},
        {'numbers': [3, 3, 8, 8, 1], 'ops': [0, 1, 2, 3]},
        {'numbers': [0, 3, 8, 8], 'ops': [0, 1, 2, 3]},
        {'numbers': [3, 3, 8, 14], 'ops': [0, 1, 2, 3]},
        {'numbers': [3, 3, 8, '8'], 'ops': [0, 1, 2, 3]},
        {'numbers': [3, 3, 8, 8.5], 'ops': [0, 1, 2, 3]},
        // 算不出 24。
        {'numbers': [1, 1, 1, 5], 'ops': [0, 1, 2, 3]},
        {'numbers': [1, 1, 1, 1], 'ops': [0, 1, 2, 3, 4, 5]},
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      expect(_rules.decodeAnswer(const []), isEmpty);
      expect(_rules.decodeAnswer(List.filled(twentyFourMaxSteps, [0, 5, 0])), hasLength(twentyFourMaxSteps));
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
          [2, 6, 0],
        ],
        [
          [4, 3, 0],
        ],
        [
          [2, 3, 4],
        ],
        [
          [2, 3, -1],
        ],
        [
          [2, 3, 0.5],
        ],
        List.filled(twentyFourMaxSteps + 1, [0, 5, 0]),
      ]) {
        expect(() => _rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('登记在数字计算、能进挑战；一句话玩法十个字以内，玩法说明提到困难起的乘方与开方', () {
      final game = playgroundCatalog.firstWhere((game) => game.id == 'twentyfour');
      expect(game.name, '24 点');
      expect(game.group, numberGroup);
      expect(game.challengeable, isTrue);
      expect(game.icon, CampusIcons.twentyfour);
      expect(game.summary.length, lessThanOrEqualTo(10));
      expect(game.howToPlay, contains('乘方'));
      expect(game.howToPlay, contains('开方'));
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
      // 入门只有加减乘除四个键，读出名字，触区至少 48。
      for (final op in [_add, _subtract, _multiply, _divide]) {
        expect(tester.getSemantics(_key(op)), isSemantics(label: _opNames[op], isButton: true, isSelected: false, isEnabled: true));
        expect(tester.getSize(find.bySemanticsLabel(_opNames[op]!)).height, greaterThanOrEqualTo(48));
      }
      expect(_key(_power), findsNothing);
      expect(_key(_root), findsNothing);
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
        await _play(tester, step);
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
      await _play(tester, _step(1, _subtract, 3));
      expect(tester.getSemantics(_card(3)), isSemantics(label: '0'));
      haptics.clear();
      await _play(tester, _step(0, _divide, 3));
      expect(haptics.last, 'HapticFeedbackType.heavyImpact');
      expect(find.text('不能除以 0'), findsOneWidget);
      expect(_status(3), findsOneWidget);
      expect(tester.getSemantics(_card(0)), isSemantics(label: '8', isSelected: true));
      expect(tester.getSemantics(_card(3)), isSemantics(label: '0'));
      expect(tester.getSemantics(_key(_divide)), isSemantics(isSelected: true));

      // 第一张与「除」还选着，直接点 5：8 ÷ 5 = 8/5（做了一步正常的，提示收起）。
      await tester.tap(_card(2));
      await _wait(tester);
      // 提示条收拢完拿掉条目，要再出一帧。
      await tester.pump();
      expect(find.text('不能除以 0'), findsNothing);
      expect(tester.getSemantics(_card(2)), isSemantics(label: '5分之8'));
      expect(find.text('8 ÷ 5 = 8/5'), findsOneWidget);
      expect(find.bySemanticsLabel('8除以5，等于5分之8'), findsOneWidget);
      expect(_status(2), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('剩一张不是 24：重震、提示得数、描警示边并读出「不是 24」，不弹结果；按步撤销退回原来的两张', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      // 入门第 0 题是 8 6 2 5：全加起来是 21。
      await _open(tester, seed: 0);
      expect(_rules.generate(0, PuzzleTier.entry).puzzle.numbers, [8, 6, 2, 5]);
      await _play(tester, _step(0, _add, 1));
      await _play(tester, _step(1, _add, 2));
      expect(find.text('8 + 6 + 2 = 16'), findsOneWidget);
      haptics.clear();
      await _play(tester, _step(2, _add, 3));
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
      expect(tester.getSemantics(_key(_add)), isSemantics(isEnabled: false));

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

    testWidgets('专家档有乘方与开方键：开方点了直接作用在选着的卡上、开完仍选着，算式写成 √9、念「根号9」，可撤销；按参考解走完弹新纪录', (tester) async {
      final semantics = tester.ensureSemantics();
      // 专家第 15 题是 1 9 10 10，参考解从 √9 起手：1 + √9 + 10 + 10。
      final store = await _open(tester, seed: 15, tier: PuzzleTier.expert);
      final draw = _rules.generate(15, PuzzleTier.expert);
      expect(draw.puzzle.numbers, [1, 9, 10, 10]);
      expect(draw.solution.first.op, _root);
      for (final op in TwentyFourOp.values) {
        expect(tester.getSemantics(_key(op)), isSemantics(label: _opNames[op], isButton: true, isEnabled: true), reason: '$op');
      }

      // 先点 9 再点开方：直接变成 3，仍选着。
      await tester.tap(_card(1));
      await _wait(tester);
      await tester.tap(_key(_root));
      await _wait(tester);
      expect(tester.getSemantics(_card(1)), isSemantics(label: '3', isSelected: true));
      expect(_status(4), findsOneWidget);
      expect(find.text('√9 = 3'), findsOneWidget);
      expect(find.bySemanticsLabel('根号9，等于3'), findsOneWidget);
      expect(tester.getSemantics(_key(_root)), isSemantics(isSelected: false));
      // 撤销回到 9；再换个顺序：先点开方（选上）、再点 9。
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _wait(tester);
      expect(tester.getSemantics(_card(1)), isSemantics(label: '9', isSelected: false));
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销')).onPressed, isNull);
      await tester.tap(_key(_root));
      await _wait(tester);
      expect(tester.getSemantics(_key(_root)), isSemantics(isSelected: true));
      await tester.tap(_card(1));
      await _wait(tester);
      expect(tester.getSemantics(_card(1)), isSemantics(label: '3', isSelected: true));

      // 接着照参考解走完：1 + √9 念「1加根号9」。
      int? picked = 1;
      for (final (index, step) in draw.solution.skip(1).indexed) {
        picked = await _play(tester, step, picked);
        if (index == 0) {
          expect(find.text('1 + √9 = 4'), findsOneWidget);
          expect(find.bySemanticsLabel('1加根号9，等于4'), findsOneWidget);
        }
      }
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      // 结果弹层与棋盘下的算式行都写着完整算式。
      expect(find.textContaining('1 + √9 + 10 + 10 = 24'), findsNWidgets(2));
      expect(store.best('twentyfour', PuzzleTier.expert), isNotNull);
      semantics.dispose();
    });

    testWidgets('乘方写成 a^b、念「几的几次方」；开不尽、开方后不变、指数不是整数、结果太大都不让做，重震并说明原因', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      // 专家第 21 题是 9 6 11 1（专家档只取解法不超过 2 种的题，原来用的 2 12 8 1 不再出现）。
      await _open(tester, seed: 21, tier: PuzzleTier.expert);
      expect(_rules.generate(21, PuzzleTier.expert).puzzle.numbers, [9, 6, 11, 1]);

      Future<void> refused(String message) async {
        expect(haptics.last, 'HapticFeedbackType.heavyImpact', reason: message);
        expect(find.text(message), findsOneWidget);
        haptics.clear();
      }

      // √6 开不尽、√1 不变：卡不变。
      await tester.tap(_card(1));
      await _wait(tester);
      await tester.tap(_key(_root));
      await _wait(tester);
      await refused('开不尽');
      expect(tester.getSemantics(_card(1)), isSemantics(label: '6', isSelected: true));
      await tester.tap(_card(3));
      await _wait(tester);
      await tester.tap(_key(_root));
      await _wait(tester);
      await refused('开方后不变');
      expect(tester.getSemantics(_card(3)), isSemantics(label: '1'));
      // 11 的 6 次方超过一百万。
      await tester.tap(_card(2));
      await _wait(tester);
      await tester.tap(_key(_power));
      await _wait(tester);
      await tester.tap(_card(1));
      await _wait(tester);
      await refused('结果太大');
      expect(tester.getSemantics(_card(1)), isSemantics(label: '6'));
      expect(_status(4), findsOneWidget);
      // 11 与乘方还选着：再点一下乘方取消。1 ÷ 6 = 1/6，再拿 9 做 1/6 次方：指数不是整数。
      await tester.tap(_key(_power));
      await _wait(tester);
      expect(tester.getSemantics(_key(_power)), isSemantics(isSelected: false));
      await tester.tap(_card(3));
      await _wait(tester);
      await tester.tap(_key(_divide));
      await _wait(tester);
      await tester.tap(_card(1));
      await _wait(tester);
      expect(tester.getSemantics(_card(1)), isSemantics(label: '6分之1'));
      await _play(tester, _step(0, _power, 1));
      await refused('指数要是整数');
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _wait(tester);
      // 撤销回到 9 6 11 1。6 的 1 次方：写成 6^1，念「6的1次方」；再加 9：乘方比加法先算，不加括号。
      await _play(tester, _step(1, _power, 3));
      expect(find.text('6^1 = 6'), findsOneWidget);
      expect(find.bySemanticsLabel('6的1次方，等于6'), findsOneWidget);
      await _play(tester, _step(0, _add, 3));
      expect(find.text('9 + 6^1 = 15'), findsOneWidget);
      expect(find.bySemanticsLabel('9加6的1次方，等于15'), findsOneWidget);
      // 15 的 11 次方：指数超过 10。
      await _play(tester, _step(3, _power, 2));
      await refused('指数要在 −$twentyFourMaxExponent 到 $twentyFourMaxExponent 之间');
      expect(_status(2), findsOneWidget);
      // 等提示条自己收起，不留下计时器。
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      semantics.dispose();
    });

    testWidgets('困难起六个运算键：360dp 加 1.3 倍字号下排成两行、每个触区不小于 48，整块不缩小', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(720, 1280);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _open(tester, seed: 15, tier: PuzzleTier.expert);
      final rows = <double>{};
      for (final op in TwentyFourOp.values) {
        final rect = tester.getRect(find.bySemanticsLabel(_opNames[op]!));
        expect(rect.height, greaterThanOrEqualTo(48), reason: '$op');
        expect(rect.width, greaterThanOrEqualTo(48), reason: '$op');
        expect(rect.left, greaterThanOrEqualTo(0), reason: '$op');
        expect(rect.right, lessThanOrEqualTo(360), reason: '$op');
        rows.add(rect.center.dy.roundToDouble());
      }
      expect(rows, hasLength(2));
      // 棋盘那一整块没有被等比缩小：卡片画出来的大小就是排版的大小。
      expect(tester.getRect(_card(0)).size, tester.getSize(_card(0)));
      expect(tester.getRect(_card(0)).height, greaterThanOrEqualTo(64));
      // 411dp 标准字号时一行放得下。
      tester.view.physicalSize = const Size(822, 1600);
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      await tester.pumpAndSettle();
      expect({for (final op in TwentyFourOp.values) tester.getRect(find.bySemanticsLabel(_opNames[op]!)).center.dy.roundToDouble()}, hasLength(1));
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
