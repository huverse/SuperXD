import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/balance/balance_page.dart';
import 'package:superxd/playground/puzzle/balance/balance_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';

const _rules = BalanceRules();

BalancePuzzle _puzzle(int balls, int weighings, {BalanceWeight weight = BalanceWeight.unknown, bool direction = false, int standards = 0, int fakes = 1, bool maybeNone = false, int seed = 0}) =>
    BalancePuzzle(balls: balls, weighings: weighings, weight: weight, direction: direction, standards: standards, fakes: fakes, maybeNone: maybeNone, seed: seed);

BalancePuzzle _fromPlan(BalancePlan plan, {bool light = false, int seed = 0}) => _puzzle(
  plan.balls,
  plan.weighings,
  weight: !plan.known ? BalanceWeight.unknown : light ? BalanceWeight.light : BalanceWeight.heavy,
  direction: plan.direction,
  standards: plan.standards,
  fakes: plan.fakes,
  maybeNone: plan.maybeNone,
  seed: seed,
);

// 每档的难易分只许落在这两级（五档分段不重叠）。
const _bands = {PuzzleTier.entry: {1, 2}, PuzzleTier.easy: {3, 4}, PuzzleTier.normal: {5, 6}, PuzzleTier.hard: {7, 8}, PuzzleTier.expert: {9, 10}};

// 物理上：假球是 balls（一个或两个）、偏重 heavy 时这次称的结果。
BalanceTilt _physical(List<int> balls, bool heavy, List<int> left, List<int> right) {
  final onLeft = balls.where(left.contains).length, onRight = balls.where(right.contains).length;
  if (onLeft == onRight) return BalanceTilt.level;
  return (onLeft > onRight) == heavy ? BalanceTilt.left : BalanceTilt.right;
}

// 每类球有几个：两向都可能、只可能偏重、只可能偏轻、确定是好球（含标准球），最后一位是还可能都是真的（1 或 0）。
(int, int, int, int, int) _counts(BalancePuzzle puzzle, BalanceSuspects suspects) {
  final both = balanceBits(suspects.heavy & suspects.light);
  final heavy = balanceBits(suspects.heavy & ~suspects.light), light = balanceBits(suspects.light & ~suspects.heavy);
  return (both, heavy, light, puzzle.total - both - heavy - light, suspects.none ? 1 : 0);
}

// 测试自己的一份极小极大（一个假球，按每类球的个数，左右盘的好球个数全部枚举，不借规则文件里的剪枝）：rounds 次内不管秤怎么答都分得清。
// 「都是真的」只在平衡时留着，算一种要分清的可能。
final _memo = <String, bool>{};
bool _canSolve((int, int, int, int, int) state, int rounds, bool direction) {
  final (u, h, l, g, z) = state;
  if ((direction ? 2 * u + h + l : u + h + l) + z <= 1) return true;
  if (rounds == 0) return false;
  return _memo['$state $rounds $direction'] ??= () {
    for (var uL = 0; uL <= u; uL++) {
      for (var uR = 0; uR <= u - uL; uR++) {
        for (var hL = 0; hL <= h; hL++) {
          for (var hR = 0; hR <= h - hL; hR++) {
            for (var lL = 0; lL <= l; lL++) {
              for (var lR = 0; lR <= l - lL; lR++) {
                for (var gL = 0; gL <= g; gL++) {
                  for (var gR = 0; gR <= g - gL; gR++) {
                    final size = uL + hL + lL + gL;
                    if (size == 0 || size != uR + hR + lR + gR) continue;
                    final total = u + h + l + g;
                    final outcomes = [
                      (0, uL + hL, uR + lR, 0),
                      (0, uR + hR, uL + lL, 0),
                      (u - uL - uR, h - hL - hR, l - lL - lR, z),
                    ];
                    if (outcomes.every((next) {
                      final (a, b, c, none) = next;
                      return a + b + c + none == 0 || _canSolve((a, b, c, total - a - b - c, none), rounds - 1, direction);
                    })) {
                      return true;
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    return false;
  }();
}

int _needed((int, int, int, int, int) state, int remaining, bool direction) {
  for (var rounds = 0; rounds <= remaining; rounds++) {
    if (_canSolve(state, rounds, direction)) return rounds;
  }
  return remaining + 1;
}

// 测试自己的两个假球求解器：按具体的称法（每个球放左、放右或不放，两边一样多）全部枚举，不分类、不去镜像。
List<(int, int)> _allWeighings(int balls) {
  final weighings = <(int, int)>[];
  for (var code = 0; code < math.pow(3, balls); code++) {
    var (left, right, rest) = (0, 0, code);
    for (var ball = 0; ball < balls; ball++) {
      if (rest % 3 == 1) left |= 1 << ball;
      if (rest % 3 == 2) right |= 1 << ball;
      rest ~/= 3;
    }
    if (left != 0 && balanceBits(left) == balanceBits(right)) weighings.add((left, right));
  }
  return weighings;
}

final _weighingsOf = <int, List<(int, int)>>{};

// 球对按「多的一边」分三份（同物理：偏重时多的一边沉）。
List<int> _pairParts(int balls, int mask, int left, int right) {
  final parts = [0, 0, 0];
  for (final (index, (first, second)) in balancePairs(balls).indexed) {
    if (mask & (1 << index) == 0) continue;
    final tilt = _physical([first, second], true, balanceMembers(left), balanceMembers(right));
    parts[tilt.index] |= 1 << index;
  }
  return parts;
}

// 穷举用的两个假球称法：对换两个球后还可能的球对一个不变的，两个球归一类（同类的球换着放结果一样），每类左右各放几个全部枚举（不去镜像、不限好球放哪边）。
List<(int, int)> _pairClassWeighings(int balls, int mask) {
  final pairs = balancePairs(balls);
  int swapped(int first, int second) {
    int image(int ball) => ball == first ? second : ball == second ? first : ball;
    var result = 0;
    for (final (index, (one, other)) in pairs.indexed) {
      if (mask >> index & 1 == 0) continue;
      final (low, high) = (math.min(image(one), image(other)), math.max(image(one), image(other)));
      result |= 1 << pairs.indexOf((low, high));
    }
    return result;
  }

  final classes = <List<int>>[];
  for (var ball = 0; ball < balls; ball++) {
    final home = classes.where((group) => swapped(group.first, ball) == mask).firstOrNull;
    if (home == null) {
      classes.add([ball]);
    } else {
      home.add(ball);
    }
  }
  var options = [(0, 0, 0)];
  for (final group in classes) {
    options = [
      for (final (left, right, difference) in options)
        for (var onLeft = 0; onLeft <= group.length; onLeft++)
          for (var onRight = 0; onLeft + onRight <= group.length; onRight++)
            (left | balanceMask(group.take(onLeft)), right | balanceMask(group.skip(onLeft).take(onRight)), difference + onLeft - onRight),
    ];
  }
  return [for (final (left, right, difference) in options) if (left != 0 && difference == 0) (left, right)];
}

final _pairMemo = <String, bool>{};
bool _pairCanSolve(int balls, int mask, int rounds) {
  if (balanceBits(mask) <= 1) return true;
  if (rounds == 0 || balanceBits(mask) > math.pow(3, rounds)) return false;
  return _pairMemo['$balls $mask $rounds'] ??= (_weighingsOf[balls] ??= _allWeighings(balls)).any(
    (weighing) => _pairParts(balls, mask, weighing.$1, weighing.$2).every((part) => part == 0 || _pairCanSolve(balls, part, rounds - 1)),
  );
}

int _pairNeeded(int balls, int mask, int remaining) {
  for (var rounds = 0; rounds <= remaining; rounds++) {
    if (_pairCanSolve(balls, mask, rounds)) return rounds;
  }
  return remaining + 1;
}

// 测试自己算的「还要称几次」（一个假球按类数，两个假球按球对）。
int _neededOf(BalancePuzzle puzzle, BalanceSuspects suspects, int remaining) =>
    puzzle.paired ? _pairNeeded(puzzle.balls, suspects.pairs, remaining) : _needed(_counts(puzzle, suspects), remaining, puzzle.direction);

bool _empty(BalanceSuspects suspects) => suspects.heavy | suspects.light | suspects.pairs == 0 && !suspects.none;

// 秤按对手规则可能给的回答：三种结果里「还要称几次」最多的那几个（平局时按种子挑其中一个）。
Set<BalanceTilt> _possible(BalancePuzzle puzzle, BalanceSuspects suspects, int left, int right, int index) {
  final keys = [
    for (final next in balanceSplit(puzzle, suspects, left, right))
      if (_empty(next)) -1 else _neededOf(puzzle, next, puzzle.weighings - index - 1),
  ];
  final top = keys.reduce(math.max);
  return {for (final (tilt, key) in keys.indexed) if (key == top) BalanceTilt.values[tilt]};
}

// 随机挑一次合规的称法：每边 1 到一半个球（可以有标准球）。
BalanceWeighing _randomWeighing(PuzzleRandom random, int total) {
  final order = [for (var ball = 0; ball < total; ball++) ball];
  random.shuffle(order);
  final size = 1 + random.nextInt(total ~/ 2);
  return BalanceWeighing(order.take(size).toList()..sort(), order.skip(size).take(size).toList()..sort());
}

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；动画按固定时长推进。
Future<void> _frames(WidgetTester tester, int millis) async {
  for (var elapsed = 0; elapsed < millis; elapsed += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder _ball(int ball) => find.bySemanticsLabel(RegExp('^${ball + 1} 号球，'));
final _standard = find.bySemanticsLabel(RegExp('^标准球，'));

Future<void> _tapFinder(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _frames(tester, 260);
}

Future<void> _tapBall(WidgetTester tester, int ball, [BalancePuzzle? puzzle]) => _tapFinder(tester, puzzle != null && ball >= puzzle.balls ? _standard : _ball(ball));

Future<void> _tool(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await _frames(tester, 300);
}

Future<void> _button(WidgetTester tester, String label) async {
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
}

// 把一次称法摆上去再称：球回到桌上、天平回平之后才返回。
Future<void> _weigh(WidgetTester tester, BalanceWeighing weighing, [BalancePuzzle? puzzle]) async {
  await _tool(tester, '放左盘');
  for (final ball in weighing.left) {
    await _tapBall(tester, ball, puzzle);
  }
  await _tool(tester, '放右盘');
  for (final ball in weighing.right) {
    await _tapBall(tester, ball, puzzle);
  }
  await _button(tester, '称一下');
  await _frames(tester, 1800);
}

// 普通档里第一道「可能都是真的」且参考解满足 matches 的种子（平局按种子答，参考解走到都是真的还是有假球跟着变）。
int _maybeNoneSeed(bool Function(PuzzleDraw<BalancePuzzle, BalanceAnswer> draw) matches) => [for (var seed = 0; seed < 400; seed++) seed].firstWhere((seed) {
  final draw = _rules.generate(seed, PuzzleTier.normal);
  return draw.puzzle.maybeNone && matches(draw);
});

Future<PlaygroundStore> _open(WidgetTester tester, PuzzleTier tier, int seed) async {
  final store = PlaygroundStore.memory();
  await store.chooseTier('balance', tier);
  final game = playgroundCatalog.firstWhere((game) => game.id == 'balance');
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: BalancePage(game: game, store: store, seeds: () => seed)));
  await tester.pumpAndSettle();
  return store;
}

// 记下触感：操作是选择触感，违规是重震。
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
  group('天平称球规则', () {
    test('出题与难度分快：每档第一道（求解器缓存还是空的）与每档 20 道', () {
      for (final tier in PuzzleTier.values) {
        final watch = Stopwatch()..start();
        for (var seed = 0; seed < 4; seed++) {
          _rules.complexity(_rules.generate(seed, tier).puzzle);
        }
        // 以前的游戏单题最慢在 100ms 量级；这里按类数（两个假球按可互换的球）搜，冷启动也只要几毫秒，留足 CI 的余量。
        expect(watch.elapsedMilliseconds, lessThan(300), reason: '$tier');
      }
      final watch = Stopwatch()..start();
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 20; seed++) {
          _rules.complexity(_rules.generate(seed, tier).puzzle);
        }
      }
      expect(watch.elapsedMilliseconds, lessThan(1500));
    });

    test('理论上限：每种题型称 k 次最多几个球，与经典结论（Dyson）一致，也与测试里另写的极小极大一致', () {
      // 一个假球：最多能分清几个（3 到 16 个里数）。
      int most(BalanceWeight weight, bool direction, int standards, int weighings, {bool maybeNone = false}) {
        var best = 0;
        for (var balls = balanceMinBalls; balls + standards <= balanceMaxTotal; balls++) {
          final puzzle = _puzzle(balls, weighings, weight: weight, direction: direction, standards: standards, maybeNone: maybeNone);
          final solvable = balanceSolvable(puzzle);
          expect(_canSolve(_counts(puzzle, balanceStart(puzzle)), weighings, direction), solvable, reason: '$balls 球 $weighings 次 $weight 说轻重=$direction 标准球=$standards 可能都是真的=$maybeNone');
          if (solvable) best = balls;
        }
        return best;
      }

      for (final weighings in [2, 3]) {
        final power = math.pow(3, weighings).toInt();
        // 已知偏重或偏轻：3^k（称 3 次时 27 超过桌面上限，16 个都分得清）。
        expect(most(BalanceWeight.heavy, false, 0, weighings), math.min(power, balanceMaxBalls));
        expect(most(BalanceWeight.light, false, 0, weighings), math.min(power, balanceMaxBalls));
        // 不知轻重只要找出：(3^k − 1) / 2，有标准球 (3^k + 1) / 2。
        expect(most(BalanceWeight.unknown, false, 0, weighings), (power - 1) ~/ 2);
        expect(most(BalanceWeight.unknown, false, 1, weighings), (power + 1) ~/ 2);
        // 还要说轻重：(3^k − 3) / 2，有标准球 (3^k − 1) / 2。
        expect(most(BalanceWeight.unknown, true, 0, weighings), (power - 3) ~/ 2);
        expect(most(BalanceWeight.unknown, true, 1, weighings), (power - 1) ~/ 2);
        // 可能都是真的：已知轻重 3^k − 1；不知轻重只需找出与说轻重都是 (3^k − 3) / 2，有标准球 (3^k − 1) / 2。
        expect(most(BalanceWeight.heavy, false, 0, weighings, maybeNone: true), math.min(power - 1, balanceMaxBalls));
        expect(most(BalanceWeight.light, false, 0, weighings, maybeNone: true), math.min(power - 1, balanceMaxBalls));
        for (final direction in [false, true]) {
          expect(most(BalanceWeight.unknown, direction, 0, weighings, maybeNone: true), (power - 3) ~/ 2, reason: '说轻重=$direction');
          expect(most(BalanceWeight.unknown, direction, 1, weighings, maybeNone: true), (power - 1) ~/ 2, reason: '说轻重=$direction');
        }
      }
      // 称 4 次不知轻重说轻重的上限是 39，桌上放得下的 16 个都分得清。
      expect(most(BalanceWeight.unknown, true, 0, 4), balanceMaxBalls);
      // 两个一样重的假球：C(n, 2) ≤ 3^k 是信息下界；求解器与测试另写的按具体称法穷举一致：称 2 次 4 个、称 3 次 7 个。
      for (final (weighings, expected) in [(1, 3), (2, 4), (3, 7)]) {
        var best = 0;
        for (var balls = 3; balls <= balanceMaxPairBalls; balls++) {
          for (final weight in [BalanceWeight.heavy, BalanceWeight.light]) {
            final puzzle = _puzzle(balls, weighings, weight: weight, fakes: 2);
            final solvable = balanceSolvable(puzzle);
            expect(_pairCanSolve(balls, balanceStart(puzzle).pairs, weighings), solvable, reason: '两个假球 $balls 个 $weighings 次');
            if (solvable) best = balls;
          }
        }
        expect(best, expected, reason: '两个假球称 $weighings 次');
      }
    });

    test('每档的每种题型：上限是紧的（给的次数找得出、少一次不行），难易分落在这一档的两级里，预计用时五档不重叠', () {
      int? lastSeconds;
      for (final MapEntry(key: tier, value: plans) in BalanceRules.pools.entries) {
        expect(plans, isNotEmpty);
        final seconds = <int>[];
        for (final plan in plans) {
          for (final light in plan.known ? [false, true] : [false]) {
            final puzzle = _fromPlan(plan, light: light);
            expect(balanceTight(puzzle), isTrue, reason: '$tier $plan');
            if (puzzle.paired) {
              expect(_pairCanSolve(puzzle.balls, balanceStart(puzzle).pairs, puzzle.weighings - 1), isFalse, reason: '$tier $plan');
            } else {
              expect(_canSolve(_counts(puzzle, balanceStart(puzzle)), puzzle.weighings - 1, puzzle.direction), isFalse, reason: '$tier $plan');
            }
            expect(_bands[tier], contains(_rules.complexity(puzzle)), reason: '$tier $plan ${balanceTreeBits(puzzle)}');
            seconds.add(_rules.expectedSeconds(puzzle));
          }
        }
        seconds.sort();
        if (lastSeconds != null) expect(seconds.first, greaterThan(lastSeconds), reason: '$tier');
        lastSeconds = seconds.last;
      }
      // 普通档 9 到 11 个球（[人工决策-2026-11-17 14:17:05]，取代 11-15 10:54:57 的 10 个球）。
      expect(BalanceRules.pools[PuzzleTier.normal]!.map((plan) => plan.balls).toSet(), {9, 10, 11});
      // 题型递进：入门只有已知轻重；两个假球、标准球、说轻重、称 4 次都出现在简单以上；可能都是真的从普通档起、每档都有。
      expect(BalanceRules.pools[PuzzleTier.entry]!.every((plan) => plan.known && plan.fakes == 1), isTrue);
      final above = [for (final tier in PuzzleTier.values.skip(1)) ...BalanceRules.pools[tier]!];
      expect(above.any((plan) => plan.fakes == 2), isTrue);
      expect(above.any((plan) => plan.standards == 1), isTrue);
      expect(above.any((plan) => plan.direction), isTrue);
      expect(above.any((plan) => plan.weighings == 4), isTrue);
      for (final tier in PuzzleTier.values) {
        expect(BalanceRules.pools[tier]!.any((plan) => plan.maybeNone), tier.index >= PuzzleTier.normal.index, reason: '$tier');
      }
      // 16 个球称 4 次的两种删掉了（用户嫌点按繁琐）。
      expect([for (final plans in BalanceRules.pools.values) ...plans].where((plan) => plan.balls == 16 && plan.weighings == 4), isEmpty);
    });

    test('每档题目多样：同档不同种子出不同的题（题型、偏哪边、平局怎么答都随种子变），同一个种子出同一道题', () {
      for (final MapEntry(key: tier, value: plans) in BalanceRules.pools.entries) {
        final draws = [for (var seed = 0; seed < 120; seed++) _rules.generate(seed, tier)];
        final puzzles = {for (final draw in draws) jsonEncode(_rules.encodePuzzle(draw.puzzle))};
        expect(puzzles, hasLength(120), reason: '$tier');
        final kinds = {for (final draw in draws) (draw.puzzle.balls, draw.puzzle.weighings, draw.puzzle.weight, draw.puzzle.direction, draw.puzzle.standards, draw.puzzle.fakes, draw.puzzle.maybeNone)};
        final expected = plans.fold(0, (sum, plan) => sum + (plan.known ? 2 : 1));
        expect(kinds, hasLength(expected), reason: '$tier 120 道里每种题型（已知轻重的偏重、偏轻各算一种）都出过');
        // 参考解最后指认的球也随种子变（平局按种子答，走到哪一支跟着变）。
        expect({for (final draw in draws) draw.solution.balls.join(',')}.length, greaterThanOrEqualTo(6), reason: '$tier');
      }
      expect(jsonEncode(_rules.encodePuzzle(_rules.generate(9, PuzzleTier.hard).puzzle)), jsonEncode(_rules.encodePuzzle(_rules.generate(9, PuzzleTier.hard).puzzle)));
    });

    test('秤的回答：和之前全部结果都对得上，留下的候选恰好是物理上说得通的那些（含标准球与两个假球），候选从不为空', () {
      final random = PuzzleRandom(77);
      for (final tier in PuzzleTier.values) {
        for (var round = 0; round < 40; round++) {
          final puzzle = _rules.generate(round, tier).puzzle;
          final plan = [for (var index = 0; index < puzzle.weighings; index++) _randomWeighing(random, puzzle.total)];
          final replay = balanceReplay(puzzle, plan)!;
          final suspects = replay.suspects;
          expect(_empty(suspects), isFalse);
          bool fits(List<int> balls, bool heavy) => plan.indexed.every((entry) => _physical(balls, heavy, entry.$2.left, entry.$2.right) == replay.tilts[entry.$1]);
          if (puzzle.paired) {
            for (final (index, (first, second)) in balancePairs(puzzle.balls).indexed) {
              expect((suspects.pairs >> index) & 1 == 1, fits([first, second], puzzle.weight == BalanceWeight.heavy), reason: '$tier $round $first $second');
            }
            continue;
          }
          for (var ball = 0; ball < puzzle.balls; ball++) {
            for (final heavy in [true, false]) {
              final allowed = puzzle.weight == BalanceWeight.unknown || (puzzle.weight == BalanceWeight.heavy) == heavy;
              expect(((heavy ? suspects.heavy : suspects.light) >> ball) & 1 == 1, allowed && fits([ball], heavy), reason: '$tier $round $ball $heavy');
            }
          }
          // 标准球从来不是候选；都是真的只在题面可能、每次都称平衡时还留着。
          expect((suspects.heavy | suspects.light) >> puzzle.balls, 0);
          expect(suspects.none, puzzle.maybeNone && replay.tilts.every((tilt) => tilt == BalanceTilt.level), reason: '$tier $round');
        }
      }
    });

    test('秤挑剩下还要称最多次的结果（测试另写的极小极大核对每一次）：称错一步一定挑到分不清的那支', () {
      final random = PuzzleRandom(5);
      for (final tier in PuzzleTier.values) {
        for (var round = 0; round < 30; round++) {
          final puzzle = _rules.generate(round, tier).puzzle;
          var suspects = balanceStart(puzzle);
          for (var index = 0; index < puzzle.weighings; index++) {
            final weighing = _randomWeighing(random, puzzle.total);
            final (left, right) = (balanceMask(weighing.left), balanceMask(weighing.right));
            final tilt = balanceRespond(puzzle, suspects, left, right, index);
            expect(_possible(puzzle, suspects, left, right, index), contains(tilt), reason: '$tier $round $index');
            suspects = balanceSplit(puzzle, suspects, left, right)[tilt.index];
          }
        }
      }
      // 12 个球先称 3 对 3：平衡剩 6 个球、两次分不清，一定答平衡；先称 5 对 5：倾斜剩 10 个、两次分不清，一定答倾斜。
      for (var seed = 0; seed < 20; seed++) {
        final puzzle = _puzzle(12, 3, seed: seed);
        final start = balanceStart(puzzle);
        expect(balanceRespond(puzzle, start, balanceMask([0, 1, 2]), balanceMask([3, 4, 5]), 0), BalanceTilt.level);
        expect(balanceRespond(puzzle, start, balanceMask([0, 1, 2, 3, 4]), balanceMask([5, 6, 7, 8, 9]), 0), isNot(BalanceTilt.level));
      }
      // 7 个里两个偏重先称 1 对 1：平衡剩 11 对（两边各一个的 1 对加不上秤的 10 对），两次分不清，一定答平衡。
      for (var seed = 0; seed < 20; seed++) {
        final puzzle = _puzzle(7, 3, weight: BalanceWeight.heavy, fakes: 2, seed: seed);
        expect(balanceRespond(puzzle, balanceStart(puzzle), balanceMask([0]), balanceMask([1]), 0), BalanceTilt.level);
      }
    });

    test('平局按种子与第几次挑：同一道题同样的称法回答一样，换种子三种结果都会出现', () {
      final seen = <BalanceTilt>{};
      for (var seed = 0; seed < 60; seed++) {
        final puzzle = _puzzle(12, 3, direction: true, seed: seed);
        final start = balanceStart(puzzle);
        // 4 对 4：三种结果都还要称 2 次，平局。
        final (left, right) = (balanceMask([0, 1, 2, 3]), balanceMask([4, 5, 6, 7]));
        final tilt = balanceRespond(puzzle, start, left, right, 0);
        expect(balanceRespond(puzzle, start, left, right, 0), tilt);
        expect(balanceRespond(_puzzle(12, 3, direction: true, seed: seed), start, balanceMask([8, 9, 10, 11]), balanceMask([0, 1, 2, 3]), 0), tilt);
        seen.add(tilt);
      }
      expect(seen, BalanceTilt.values.toSet());
      final draw = _rules.generate(9, PuzzleTier.hard);
      final again = _rules.generate(9, PuzzleTier.hard);
      expect(draw.puzzle.seed, again.puzzle.seed);
      expect(balanceReplay(draw.puzzle, draw.solution.weighings)!.tilts, balanceReplay(again.puzzle, again.solution.weighings)!.tilts);
      expect(_rules.generate(10, PuzzleTier.hard).puzzle.seed, isNot(draw.puzzle.seed));
    });

    test('穷举每档每种题型：秤可能给的每一种回答都按玩家最有利的算，玩家赢得了的局面也恰好是极小极大下来得及的，而且一定称满次数才分清（靠运气赢不了）', () {
      for (final MapEntry(key: tier, value: plans) in BalanceRules.pools.entries) {
        for (final plan in plans) {
          for (final light in plan.known ? [false, true] : [false]) {
            final puzzle = _fromPlan(plan, light: light, seed: 3);
            final memo = <String, bool>{};
            var visited = 0;
            // 这一步能放的称法，同类的球换着放结果一样：两个假球按 _pairClassWeighings；一个假球按类数（每类按编号从小取，好球补在少的一边）。
            List<(int, int)> weighingsOf(BalanceSuspects suspects) {
              if (puzzle.paired) return _pairClassWeighings(puzzle.balls, suspects.pairs);
              final (u, h, l, g, _) = _counts(puzzle, suspects);
              final both = balanceMembers(suspects.heavy & suspects.light);
              final heavy = balanceMembers(suspects.heavy & ~suspects.light), lightOnes = balanceMembers(suspects.light & ~suspects.heavy);
              final good = [for (var ball = 0; ball < puzzle.total; ball++) if ((suspects.heavy | suspects.light) >> ball & 1 == 0) ball];
              return [
                for (var uL = 0; uL <= u; uL++)
                  for (var uR = 0; uR <= u - uL; uR++)
                    for (var hL = 0; hL <= h; hL++)
                      for (var hR = 0; hR <= h - hL; hR++)
                        for (var lL = 0; lL <= l; lL++)
                          for (var lR = 0; lR <= l - lL; lR++)
                            if (uL + hL + lL + uR + hR + lR > 0 && (uL + hL + lL - uR - hR - lR).abs() <= g)
                              (
                                balanceMask([...both.take(uL), ...heavy.take(hL), ...lightOnes.take(lL), ...good.take(math.max(0, uR + hR + lR - uL - hL - lL))]),
                                balanceMask([...both.skip(uL).take(uR), ...heavy.skip(hL).take(hR), ...lightOnes.skip(lL).take(lR), ...good.skip(math.max(0, uR + hR + lR - uL - hL - lL)).take(math.max(0, uL + hL + lL - uR - hR - lR))]),
                              ),
              ];
            }

            bool done(BalanceSuspects suspects) => puzzle.paired ? balanceBits(suspects.pairs) <= 1 : _canSolve(_counts(puzzle, suspects), 0, puzzle.direction);
            // 玩家赢得了：有一种称法，秤可能给的回答里只要有一种接着赢得了就算（平局全按玩家最有利的挑）。
            // 一个假球的局面按类数记（类数一样，胜负一样）；两个假球按球对的位集记。
            bool win(BalanceSuspects suspects, int index) {
              final key = puzzle.paired ? '${suspects.pairs} $index' : '${_counts(puzzle, suspects)} $index';
              if (memo[key] case final known?) return known;
              visited++;
              final finished = done(suspects);
              // 上限是紧的：次数没用完之前，按对手规则走到的局面一个都还没分清。
              expect(finished && index < puzzle.weighings, isFalse, reason: '$tier $plan 第 $index 次前就分清了');
              var result = finished;
              if (!result && index < puzzle.weighings) {
                for (final (left, right) in weighingsOf(suspects)) {
                  final outcomes = balanceSplit(puzzle, suspects, left, right);
                  final answers = _possible(puzzle, suspects, left, right, index);
                  // 规则里的秤（这道题的种子）也只会在这几种里挑。
                  expect(answers, contains(balanceRespond(puzzle, suspects, left, right, index)));
                  if (answers.any((tilt) => win(outcomes[tilt.index], index + 1))) {
                    result = true;
                    break;
                  }
                }
              }
              final remaining = puzzle.weighings - index;
              final solvable = puzzle.paired ? _pairCanSolve(puzzle.balls, suspects.pairs, remaining) : _canSolve(_counts(puzzle, suspects), remaining, puzzle.direction);
              expect(result, solvable, reason: '$tier $plan 第 $index 次前');
              return memo[key] = result;
            }

            expect(win(balanceStart(puzzle), 0), isTrue, reason: '$tier $plan');
            expect(visited, greaterThan(1), reason: '$tier $plan');
          }
        }
      }
    });

    test('每档 20 道：参考解按规则判定通过、正好称满次数、最后候选恰好是指认的那个（那一对，或都是真的）', () {
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 20; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle, solution = draw.solution;
          expect(_rules.solved(puzzle, solution), isTrue, reason: '$tier $seed');
          expect(solution.weighings, hasLength(puzzle.weighings), reason: '$tier $seed');
          expect(solution.heavy != null, puzzle.direction && solution.balls.isNotEmpty);
          expect(solution.balls, hasLength(solution.balls.isEmpty && puzzle.maybeNone ? 0 : puzzle.fakes));
          final suspects = balanceReplay(puzzle, solution.weighings)!.suspects;
          expect(balanceVerdict(puzzle, suspects, solution.balls, solution.heavy), BalanceVerdict.solved);
        }
      }
      expect(jsonEncode(_rules.encodeAnswer(_rules.generate(4, PuzzleTier.expert).solution)), jsonEncode(_rules.encodeAnswer(_rules.generate(4, PuzzleTier.expert).solution)));
    });

    test('违规不算解开：超次数、两边球数不等、有一边空、同一个球两边都放、编号越界、还确定不了就指认、指认的不是候选、轻重说错或该说没说', () {
      // 困难种子 3 是 11 个球说轻重称 3 次。
      final draw = _rules.generate(3, PuzzleTier.hard);
      final puzzle = draw.puzzle, solution = draw.solution;
      expect((puzzle.balls, puzzle.direction, puzzle.standards), (11, true, 0));
      BalanceAnswer variant({List<BalanceWeighing>? weighings, List<int>? balls, bool? heavy, bool keepHeavy = true}) =>
          BalanceAnswer(weighings ?? solution.weighings, balls ?? solution.balls, keepHeavy ? heavy ?? solution.heavy : null);
      final first = solution.balls.single;
      expect(_rules.solved(puzzle, solution), isTrue);
      expect(_rules.solved(puzzle, variant(weighings: [...solution.weighings, const BalanceWeighing([0], [1])])), isFalse);
      expect(_rules.solved(puzzle, variant(weighings: [const BalanceWeighing([0, 1], [2]), ...solution.weighings.skip(1)])), isFalse);
      expect(_rules.solved(puzzle, variant(weighings: [const BalanceWeighing([], [2]), ...solution.weighings.skip(1)])), isFalse);
      expect(_rules.solved(puzzle, variant(weighings: [const BalanceWeighing([0, 1], [1, 2]), ...solution.weighings.skip(1)])), isFalse);
      expect(_rules.solved(puzzle, variant(weighings: [const BalanceWeighing([0, 1], [2, 11]), ...solution.weighings.skip(1)])), isFalse);
      expect(_rules.solved(puzzle, variant(weighings: solution.weighings.take(2).toList())), isFalse);
      expect(_rules.solved(puzzle, variant(balls: [(first + 1) % puzzle.balls])), isFalse);
      expect(_rules.solved(puzzle, variant(balls: [first, (first + 1) % puzzle.balls])), isFalse);
      expect(_rules.solved(puzzle, variant(heavy: !solution.heavy!)), isFalse);
      expect(_rules.solved(puzzle, variant(keepHeavy: false)), isFalse);
      // 只需找出的题不收轻重；标准球可以上秤、不能指认。普通种子 11 是 10 个球加 1 个标准球只需找出。
      final find = _rules.generate(11, PuzzleTier.normal);
      expect((find.puzzle.balls, find.puzzle.standards, find.puzzle.direction, find.puzzle.maybeNone), (10, 1, false, false));
      expect(_rules.solved(find.puzzle, find.solution), isTrue);
      expect(_rules.solved(find.puzzle, BalanceAnswer(find.solution.weighings, find.solution.balls, true)), isFalse);
      expect(balanceFault(find.puzzle, [0, 10], [1, 2]), isNull);
      expect(balanceFault(find.puzzle, [0, 11], [1, 2]), BalanceFault.invalid);
      final findSuspects = balanceReplay(find.puzzle, find.solution.weighings)!.suspects;
      expect(balanceVerdict(find.puzzle, findSuspects, [10], null), BalanceVerdict.contradicts);
      // 两个假球：要指认两个，说一个、说三个、对子不对都不算。简单种子 4 是 6 个里两个偏轻称 3 次。
      final pair = _rules.generate(4, PuzzleTier.easy);
      expect((pair.puzzle.balls, pair.puzzle.fakes, pair.puzzle.weight), (6, 2, BalanceWeight.light));
      expect(_rules.solved(pair.puzzle, pair.solution), isTrue);
      expect(_rules.solved(pair.puzzle, BalanceAnswer(pair.solution.weighings, pair.solution.balls.reversed.toList())), isTrue);
      expect(_rules.solved(pair.puzzle, BalanceAnswer(pair.solution.weighings, [pair.solution.balls.first])), isFalse);
      expect(_rules.solved(pair.puzzle, BalanceAnswer(pair.solution.weighings, [...pair.solution.balls, 5 - pair.solution.balls.last])), isFalse);
      final other = [for (var ball = 0; ball < 6; ball++) if (!pair.solution.balls.contains(ball)) ball].take(2).toList();
      expect(_rules.solved(pair.puzzle, BalanceAnswer(pair.solution.weighings, other)), isFalse);
      // 指认的判定：一开始谁都还确定不了；参考解称完后，别的球都对不上。
      final start = balanceStart(puzzle);
      expect(balanceVerdict(puzzle, start, [0], true), BalanceVerdict.undetermined);
      final suspects = balanceReplay(puzzle, solution.weighings)!.suspects;
      expect(balanceVerdict(puzzle, suspects, [(first + 1) % puzzle.balls], true), BalanceVerdict.contradicts);
      expect(balanceVerdict(puzzle, suspects, [first], !solution.heavy!), BalanceVerdict.contradicts);
      expect(balanceVerdict(pair.puzzle, balanceStart(pair.puzzle), [0, 1], null), BalanceVerdict.undetermined);
      // 只剩一个球、还不知道轻重：要说轻重的题还确定不了，只需找出的题已经找出来了。
      const both = (heavy: 1 << 5, light: 1 << 5, pairs: 0, none: false);
      expect(balanceVerdict(puzzle, both, [5], true), BalanceVerdict.undetermined);
      expect(balanceVerdict(puzzle, both, [5], false), BalanceVerdict.undetermined);
      expect(balanceVerdict(find.puzzle, both, [5], null), BalanceVerdict.solved);
      expect(balanceFault(puzzle, [0, 1], [2]), BalanceFault.uneven);
      expect(balanceFault(puzzle, [0], []), BalanceFault.empty);
      expect(balanceFault(puzzle, [0, 0], [1, 2]), BalanceFault.invalid);
      expect(balanceFault(puzzle, [0], [1]), isNull);
    });

    test('可能都是真的：只剩都是真的时答「都是真的」才算，答成某个球或带了轻重不算；还剩假球或题面不可能时答都是真的不算', () {
      // 普通档里参考解走到都是真的、走到有假球的各一道（平局按种子答，走到哪一支跟着变）。
      final draws = [for (var seed = 0; seed < 400; seed++) _rules.generate(seed, PuzzleTier.normal)].where((draw) => draw.puzzle.maybeNone).toList();
      final none = draws.firstWhere((draw) => draw.solution.balls.isEmpty), fake = draws.firstWhere((draw) => draw.solution.balls.isNotEmpty);
      expect(none.solution.heavy, isNull);
      expect(_rules.solved(none.puzzle, none.solution), isTrue);
      final wrongBall = BalanceAnswer(none.solution.weighings, [0], none.puzzle.direction ? true : null);
      expect(_rules.solved(none.puzzle, wrongBall), isFalse);
      expect(_rules.solved(none.puzzle, BalanceAnswer(none.solution.weighings, const [], true)), isFalse);
      final noneSuspects = balanceReplay(none.puzzle, none.solution.weighings)!.suspects;
      expect(noneSuspects, (heavy: 0, light: 0, pairs: 0, none: true));
      expect(balanceVerdict(none.puzzle, noneSuspects, [0], wrongBall.heavy), BalanceVerdict.contradicts);
      // 还有假球：答都是真的对不上；一开始谁都还确定不了，都是真的也是。
      expect(_rules.solved(fake.puzzle, BalanceAnswer(fake.solution.weighings, const [])), isFalse);
      expect(balanceVerdict(fake.puzzle, balanceReplay(fake.puzzle, fake.solution.weighings)!.suspects, const [], null), BalanceVerdict.contradicts);
      expect(balanceVerdict(fake.puzzle, balanceStart(fake.puzzle), const [], null), BalanceVerdict.undetermined);
      // 只剩一个球但还可能都是真的：指认那个球还确定不了。
      const ballOrNone = (heavy: 1 << 5, light: 0, pairs: 0, none: true);
      expect(balanceVerdict(none.puzzle, ballOrNone, [5], none.puzzle.direction ? true : null), BalanceVerdict.undetermined);
      expect(balanceVerdict(none.puzzle, ballOrNone, const [], null), BalanceVerdict.undetermined);
      // 题面不可能都是真的：答都是真的一律对不上。困难种子 3 是 11 个球说轻重。
      final plain = _rules.generate(3, PuzzleTier.hard);
      expect(plain.puzzle.maybeNone, isFalse);
      expect(_rules.solved(plain.puzzle, BalanceAnswer(plain.solution.weighings, const [])), isFalse);
      expect(balanceVerdict(plain.puzzle, balanceStart(plain.puzzle), const [], null), BalanceVerdict.contradicts);
    });

    test('难度分：同一题型同分、种子不影响，解不开的按 10 分', () {
      for (final tier in PuzzleTier.values) {
        final scores = <String, Set<int>>{};
        for (var seed = 0; seed < 30; seed++) {
          final puzzle = _rules.generate(seed, tier).puzzle;
          scores.putIfAbsent('${puzzle.balls} ${puzzle.weighings} ${puzzle.weight} ${puzzle.direction} ${puzzle.standards} ${puzzle.fakes} ${puzzle.maybeNone}', () => {}).add(_rules.complexity(puzzle));
        }
        for (final MapEntry(key: kind, value: values) in scores.entries) {
          expect(values, hasLength(1), reason: '$tier $kind');
          expect(_bands[tier], contains(values.single), reason: '$tier $kind');
        }
      }
      expect(_rules.complexity(_puzzle(13, 3, direction: true)), 10);
      expect(_rules.complexity(_puzzle(8, 3, weight: BalanceWeight.heavy, fakes: 2)), 10);
    });

    test('编解码往返（第 2 版写法），坏输入抛 FormatException', () {
      expect(_rules.puzzleVersion, 2);
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 8; seed++) {
          final draw = _rules.generate(seed, tier);
          final json = jsonDecode(jsonEncode(_rules.encodePuzzle(draw.puzzle)));
          final puzzle = _rules.decodePuzzle(json);
          expect(_rules.encodePuzzle(puzzle), _rules.encodePuzzle(draw.puzzle));
          final answer = _rules.decodeAnswer(jsonDecode(jsonEncode(_rules.encodeAnswer(draw.solution))));
          expect(_rules.solved(puzzle, answer), isTrue);
          expect(answer.heavy, draw.solution.heavy);
          expect(answer.balls, draw.solution.balls);
        }
      }
      const good = {'balls': 12, 'standards': 0, 'fakes': 1, 'weight': 'unknown', 'direction': true, 'maybeNone': false, 'weighings': 3, 'seed': 5};
      expect(_rules.decodePuzzle(good).direction, isTrue);
      expect(_rules.decodePuzzle({...good, 'maybeNone': true}).maybeNone, isTrue);
      expect(_rules.decodePuzzle({...good, 'balls': 7, 'fakes': 2, 'weight': 'light', 'direction': false}).paired, isTrue);
      expect(_rules.decodePuzzle({...good, 'balls': 13, 'standards': 1}).standards, 1);
      for (final bad in <Object?>[
        null,
        '12',
        {...good, 'balls': 2},
        {...good, 'balls': 17},
        {...good, 'balls': '12'},
        {...good, 'standards': 2},
        {...good, 'standards': -1},
        {...good, 'fakes': 0},
        {...good, 'fakes': 3},
        {...good, 'weighings': 0},
        {...good, 'weighings': 5},
        {...good, 'seed': -1},
        {...good, 'seed': 0x100000000},
        {...good, 'weight': 'heavier'},
        {...good, 'weight': null},
        {...good, 'direction': null},
        {...good, 'direction': 1},
        {...good, 'maybeNone': null},
        {...good, 'maybeNone': 0},
        // 已知轻重就不用说轻重。
        {...good, 'weight': 'heavy'},
        // 桌上最多 16 个。
        {...good, 'balls': 16, 'standards': 1, 'weighings': 4},
        // 两个假球：要已知轻重、不带标准球、不会都是真的、最多 8 个。
        {...good, 'balls': 6, 'fakes': 2, 'direction': false},
        {...good, 'balls': 6, 'fakes': 2, 'weight': 'heavy', 'direction': false, 'maybeNone': true},
        {...good, 'balls': 6, 'fakes': 2, 'weight': 'heavy', 'direction': false, 'standards': 1},
        {...good, 'balls': 9, 'fakes': 2, 'weight': 'heavy', 'direction': false, 'weighings': 4},
        // 在限定次数内找不出：13 个球称 3 次还要说轻重、13 个只需找出但可能都是真的、10 个已知偏重称 2 次、8 个里两个假球称 3 次。
        {...good, 'balls': 13},
        {...good, 'balls': 13, 'direction': false, 'maybeNone': true},
        {...good, 'balls': 10, 'weight': 'heavy', 'direction': false, 'weighings': 2},
        {...good, 'balls': 8, 'fakes': 2, 'weight': 'heavy', 'direction': false},
        // 第 1 版的写法不收。
        {'balls': 9, 'weighings': 2, 'knownHeavy': true, 'direction': false, 'seed': 0},
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      expect(_rules.decodeAnswer({'weighings': <Object>[], 'balls': [3]}).heavy, isNull);
      expect(_rules.decodeAnswer({'weighings': <Object>[], 'balls': [3, 5]}).balls, [3, 5]);
      expect(_rules.decodeAnswer({'weighings': <Object>[], 'balls': <Object>[]}).balls, isEmpty);
      for (final bad in <Object?>[
        null,
        [1],
        {'weighings': <Object>[], 'balls': [1, 1]},
        {'weighings': <Object>[], 'balls': [1, 2, 3]},
        {'weighings': <Object>[], 'balls': [16]},
        {'weighings': <Object>[], 'balls': '1'},
        {'weighings': <Object>[], 'ball': 1},
        {'weighings': <Object>[], 'balls': [1], 'heavy': 1},
        {'weighings': [[[0], [1]], [[0], [1]], [[0], [1]], [[0], [1]], [[0], [1]]], 'balls': [1]},
        {'weighings': [[[0], [0]]], 'balls': [1]},
        {'weighings': [[[0, 0], [1, 2]]], 'balls': [1]},
        {'weighings': [[[0], [1], [2]]], 'balls': [1]},
        {'weighings': [[[0], [16]]], 'balls': [1]},
        {'weighings': [[[0], '1']], 'balls': [1]},
        {'weighings': '0|1', 'balls': [1]},
      ]) {
        expect(() => _rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('登记在逻辑推理、能进挑战，一句话玩法十个字以内', () {
      final game = playgroundCatalog.firstWhere((game) => game.id == 'balance');
      expect(game.name, '天平称球');
      expect(game.group, logicGroup);
      expect(game.challengeable, isTrue);
      expect(game.summary.length, lessThanOrEqualTo(10));
    });
  });

  group('天平称球对局页', () {
    testWidgets('放球、拿回、称一次：记一行结果，球回到桌上；两边不等被拒并说明原因，接着放球就收起提示', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      // 入门种子 2 是 9 个已知偏重称 2 次。
      await _open(tester, PuzzleTier.entry, 2);
      final puzzle = _rules.generate(2, PuzzleTier.entry).puzzle;
      expect(find.text('9 个球，最多称 2 次'), findsOneWidget);
      expect(find.text('其中一个偏重，找出它'), findsOneWidget);
      expect(find.textContaining('称了 0/2 次'), findsOneWidget);
      expect(find.bySemanticsLabel('1 号球，在桌上'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '称一下')).onPressed, isNull);

      // 左盘两个、右盘一个：称不了，重震，提示条写原因，次数不变。
      await _tapBall(tester, 0);
      await _tapBall(tester, 1);
      await _tool(tester, '放右盘');
      await _tapBall(tester, 2);
      expect(find.bySemanticsLabel('1 号球，在左盘'), findsOneWidget);
      expect(find.bySemanticsLabel('3 号球，在右盘'), findsOneWidget);
      expect(find.bySemanticsLabel('天平：左盘有 1、2 号，右盘有 3 号'), findsOneWidget);
      haptics.clear();
      await _button(tester, '称一下');
      await _frames(tester, 300);
      expect(find.text('两边球数要一样'), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.heavyImpact']);
      expect(find.textContaining('称了 0/2 次'), findsOneWidget);

      // 点盘里的球拿回桌上是一步正常操作：过时的提示马上收起。
      await _tapBall(tester, 1);
      await _frames(tester, 400);
      expect(find.text('两边球数要一样'), findsNothing);
      expect(find.bySemanticsLabel('2 号球，在桌上'), findsOneWidget);

      // 1 对 3：称了，记一行，球回到桌上。
      await _button(tester, '称一下');
      await tester.pump();
      final tilt = balanceRespond(puzzle, balanceStart(puzzle), balanceMask([0]), balanceMask([2]), 0);
      expect(find.bySemanticsLabel('第 1 次：左盘 1 号，右盘 3 号，${balanceTiltName(tilt)}'), findsOneWidget);
      expect(find.textContaining('称了 1/2 次'), findsOneWidget);
      expect(find.bySemanticsLabel('1 号球，在左盘'), findsOneWidget);
      await _frames(tester, 1800);
      expect(find.bySemanticsLabel('1 号球，在桌上'), findsOneWidget);
      expect(find.bySemanticsLabel('3 号球，在桌上'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('指认：还确定不了时重震提示，次数还有就回到称球；次数用完再放球被拒，提示从头来', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      // 入门种子 9 是 6 个已知偏重称 2 次。
      await _open(tester, PuzzleTier.entry, 9);
      final puzzle = _rules.generate(9, PuzzleTier.entry).puzzle;
      expect((puzzle.balls, puzzle.weighings, puzzle.weight), (6, 2, BalanceWeight.heavy));
      await _button(tester, '指认');
      await _frames(tester, 300);
      expect(find.textContaining('点一个球指认'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认')).onPressed, isNull);
      await _tapBall(tester, 4);
      expect(tester.getSemantics(_ball(4)), isSemantics(label: '5 号球，在桌上', isButton: true, isSelected: true, hasTapAction: true));
      haptics.clear();
      await _button(tester, '确认');
      await _frames(tester, 300);
      expect(find.text('还确定不了'), findsOneWidget);
      expect(haptics.last, 'HapticFeedbackType.heavyImpact');
      expect(find.widgetWithText(FilledButton, '称一下'), findsOneWidget);

      // 称两次（随便称），次数用完：再放球被拒；指认还确定不了时提示从头来，留在指认里。
      await _weigh(tester, const BalanceWeighing([0], [1]));
      await _weigh(tester, const BalanceWeighing([2], [3]));
      expect(find.textContaining('称了 2/2 次'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '称一下')).onPressed, isNull);
      await _tool(tester, '放左盘');
      await _tapBall(tester, 5);
      expect(find.text('2 次都称过了，点「指认」'), findsOneWidget);
      expect(find.bySemanticsLabel('6 号球，在桌上'), findsOneWidget);
      final suspects = balanceReplay(puzzle, const [BalanceWeighing([0], [1]), BalanceWeighing([2], [3])])!.suspects;
      expect(balanceBits(suspects.heavy), greaterThan(1));
      final candidate = balanceMembers(suspects.heavy).first;
      await _button(tester, '指认');
      await _frames(tester, 300);
      await _tapBall(tester, candidate);
      await _button(tester, '确认');
      await _frames(tester, 300);
      expect(find.text('还确定不了，次数已用完'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '确认'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('按参考称法走完：指认那个球解开，球鼓一下再弹新纪录，可换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = await _open(tester, PuzzleTier.entry, 2);
      final solution = _rules.generate(2, PuzzleTier.entry).solution;
      for (final weighing in solution.weighings) {
        await _weigh(tester, weighing);
      }
      await _button(tester, '指认');
      await _frames(tester, 300);
      // 先指认一个已经排除的：对不上，记一次指认错。
      final ball = solution.balls.single, wrong = (solution.balls.single + 1) % 9;
      await _tapBall(tester, wrong);
      await _button(tester, '确认');
      await _frames(tester, 300);
      expect(find.text('${wrong + 1} 号和称的结果对不上'), findsOneWidget);
      // 次数用完了，留在指认里，直接换一个。
      expect(find.widgetWithText(FilledButton, '确认'), findsOneWidget);
      await _tapBall(tester, ball);
      await _button(tester, '确认');
      await tester.pump();
      expect(find.text('新纪录'), findsNothing);
      await _frames(tester, 300);
      expect(find.bySemanticsLabel('${ball + 1} 号球，在桌上，就是它'), findsOneWidget);
      await _frames(tester, 900);
      expect(find.text('新纪录'), findsOneWidget);
      // 结果说明行按「 · 」分项排，各项分开找。
      expect(find.textContaining(RegExp('^称 2 次')), findsOneWidget);
      expect(find.textContaining('指认错 1 次'), findsOneWidget);
      expect(store.best('balance', PuzzleTier.entry)!.moves, 2);
      await tester.tap(find.text('换到简单'));
      await _frames(tester, 600);
      expect(store.tierOf('balance'), PuzzleTier.easy);
      // 简单种子 2 是 8 个不知轻重只需找出称 3 次。
      expect(find.text('8 个球，最多称 3 次'), findsOneWidget);
      expect(find.text('有一个轻重不明，找出它'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('要说轻重的题：选偏重或偏轻才能确认，说对了才解开', (tester) async {
      final semantics = tester.ensureSemantics();
      // 困难种子 3 是 11 个球说轻重称 3 次。
      await _open(tester, PuzzleTier.hard, 3);
      expect(find.text('有一个轻重不明，找出它并说出轻重'), findsOneWidget);
      final solution = _rules.generate(3, PuzzleTier.hard).solution;
      final ball = solution.balls.single;
      for (final weighing in solution.weighings) {
        await _weigh(tester, weighing);
      }
      await _button(tester, '指认');
      await _frames(tester, 300);
      await _tapBall(tester, ball);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认')).onPressed, isNull);
      await tester.tap(find.text(solution.heavy! ? '偏轻' : '偏重'));
      await _frames(tester, 300);
      await _button(tester, '确认');
      await _frames(tester, 300);
      expect(find.text('${ball + 1} 号${solution.heavy! ? '偏轻' : '偏重'}和称的结果对不上'), findsOneWidget);
      await _tapBall(tester, ball);
      await tester.tap(find.text(solution.heavy! ? '偏重' : '偏轻'));
      await _frames(tester, 300);
      await _button(tester, '确认');
      await _frames(tester, 1500);
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('两个假球：点两个球才能确认，再点取消、第三个换掉先选的；对子不对提示，两个都对才解开、一起鼓一下', (tester) async {
      final semantics = tester.ensureSemantics();
      // 简单种子 4 是 6 个里两个一样偏轻称 3 次。
      await _open(tester, PuzzleTier.easy, 4);
      expect(find.text('6 个球，最多称 3 次'), findsOneWidget);
      expect(find.text('其中两个一样偏轻，找出这两个'), findsOneWidget);
      final draw = _rules.generate(4, PuzzleTier.easy);
      final solution = draw.solution;
      for (final weighing in solution.weighings) {
        await _weigh(tester, weighing);
      }
      await _button(tester, '指认');
      await _frames(tester, 300);
      expect(find.textContaining('点两个球指认'), findsOneWidget);
      final [first, second] = solution.balls;
      final others = [for (var ball = 0; ball < 6; ball++) if (!solution.balls.contains(ball)) ball];
      bool confirmable() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认')).onPressed != null;
      await _tapBall(tester, first);
      expect(confirmable(), isFalse);
      await _tapBall(tester, others[0]);
      expect(confirmable(), isTrue);
      // 第三个换掉先选的那个；再点选着的取消。
      await _tapBall(tester, second);
      expect(tester.getSemantics(_ball(first)), isSemantics(label: '${first + 1} 号球，在桌上', isButton: true, isSelected: false, hasTapAction: true));
      expect(tester.getSemantics(_ball(others[0])), isSemantics(label: '${others[0] + 1} 号球，在桌上', isButton: true, isSelected: true, hasTapAction: true));
      await _tapBall(tester, others[0]);
      expect(confirmable(), isFalse);
      // 对子不对：提示，次数用完留在指认里。
      await _tapBall(tester, others[1]);
      await _button(tester, '确认');
      await _frames(tester, 300);
      final shown = [second, others[1]]..sort();
      expect(find.text('${shown[0] + 1}、${shown[1] + 1} 号和称的结果对不上'), findsOneWidget);
      await _tapBall(tester, first);
      await _tapBall(tester, second);
      await _button(tester, '确认');
      await _frames(tester, 300);
      expect(find.bySemanticsLabel('${first + 1} 号球，在桌上，就是它'), findsOneWidget);
      expect(find.bySemanticsLabel('${second + 1} 号球，在桌上，就是它'), findsOneWidget);
      await _frames(tester, 1200);
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('标准球：写「标」排在最后，能上秤、记录与读屏念「标准球」，不能做记号也不能指认，按参考称法走完解开', (tester) async {
      final semantics = tester.ensureSemantics();
      // 普通种子 11 是 10 个球加 1 个标准球只需找出。
      await _open(tester, PuzzleTier.normal, 11);
      final draw = _rules.generate(11, PuzzleTier.normal);
      final puzzle = draw.puzzle;
      expect(find.text('10 个球和 1 个标准球，最多称 3 次'), findsOneWidget);
      expect(find.text('有一个轻重不明，找出它；标准球是真的'), findsOneWidget);
      expect(find.bySemanticsLabel('标准球，在桌上'), findsOneWidget);
      expect(find.text('标'), findsOneWidget);
      await _tool(tester, '做记号');
      await _tapFinder(tester, _standard);
      expect(find.text('标准球是真的'), findsOneWidget);
      expect(find.bySemanticsLabel('标准球，在桌上'), findsOneWidget);
      // 标准球上秤：1 号与标准球对 2、3 号。
      await _weigh(tester, const BalanceWeighing([0, 10], [1, 2]), puzzle);
      final tilt = balanceRespond(puzzle, balanceStart(puzzle), balanceMask([0, 10]), balanceMask([1, 2]), 0);
      expect(find.bySemanticsLabel('第 1 次：左盘 1 号与标准球，右盘 2、3 号，${balanceTiltName(tilt)}'), findsOneWidget);
      // 指认时点标准球被拒。
      await _button(tester, '指认');
      await _frames(tester, 300);
      await _tapFinder(tester, _standard);
      expect(find.text('标准球是真的'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认')).onPressed, isNull);
      await _button(tester, '取消');
      await _frames(tester, 300);
      // 从头来，按参考称法走完。
      await tester.tap(find.byTooltip('更多操作'));
      await _frames(tester, 400);
      await tester.tap(find.text('这一题从头来'));
      await _frames(tester, 400);
      expect(draw.solution.weighings.any((weighing) => [...weighing.left, ...weighing.right].contains(10)), isTrue, reason: '参考解用到了标准球');
      for (final weighing in draw.solution.weighings) {
        await _weigh(tester, weighing, puzzle);
      }
      await _button(tester, '指认');
      await _frames(tester, 300);
      await _tapBall(tester, draw.solution.balls.single);
      await _button(tester, '确认');
      await _frames(tester, 1500);
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('可能都是真的、还有假球：选「都是真的」才能单独确认，点球就换掉它；称完答都是真的提示对不上，指认那个球解开', (tester) async {
      final semantics = tester.ensureSemantics();
      final fakeSeed = _maybeNoneSeed((draw) => draw.solution.balls.isNotEmpty);
      final fake = _rules.generate(fakeSeed, PuzzleTier.normal);
      await _open(tester, PuzzleTier.normal, fakeSeed);
      expect(find.textContaining('也可能都是真的'), findsOneWidget);
      for (final weighing in fake.solution.weighings) {
        await _weigh(tester, weighing, fake.puzzle);
      }
      await _button(tester, '指认');
      await _frames(tester, 300);
      bool confirmable() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认')).onPressed != null;
      expect(confirmable(), isFalse);
      await tester.tap(find.text('都是真的'));
      await _frames(tester, 300);
      expect(confirmable(), isTrue);
      // 点了球就不再是都是真的。
      await _tapBall(tester, fake.solution.balls.single);
      expect(confirmable(), fake.puzzle.direction ? isFalse : isTrue);
      await tester.tap(find.text('都是真的'));
      await _frames(tester, 300);
      expect(tester.getSemantics(_ball(fake.solution.balls.single)), isSemantics(label: '${fake.solution.balls.single + 1} 号球，在桌上', isButton: true, isSelected: false, hasTapAction: true));
      await _button(tester, '确认');
      await _frames(tester, 300);
      expect(find.text('「都是真的」和称的结果对不上'), findsOneWidget);
      await _tapBall(tester, fake.solution.balls.single);
      if (fake.puzzle.direction) {
        await tester.tap(find.text(fake.solution.heavy! ? '偏重' : '偏轻'));
        await _frames(tester, 300);
      }
      await _button(tester, '确认');
      await _frames(tester, 1500);
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('可能都是真的、只剩都是真的：答成某个球提示对不上，答都是真的解开（没有要鼓的球，直接弹结果）', (tester) async {
      final semantics = tester.ensureSemantics();
      final noneSeed = _maybeNoneSeed((draw) => draw.solution.balls.isEmpty);
      final none = _rules.generate(noneSeed, PuzzleTier.normal);
      await _open(tester, PuzzleTier.normal, noneSeed);
      for (final weighing in none.solution.weighings) {
        await _weigh(tester, weighing, none.puzzle);
      }
      await _button(tester, '指认');
      await _frames(tester, 300);
      await _tapBall(tester, 0);
      if (none.puzzle.direction) {
        await tester.tap(find.text('偏重'));
        await _frames(tester, 300);
      }
      await _button(tester, '确认');
      await _frames(tester, 300);
      expect(find.textContaining('和称的结果对不上'), findsOneWidget);
      await tester.tap(find.text('都是真的'));
      await _frames(tester, 300);
      await _button(tester, '确认');
      await _frames(tester, 400);
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('做记号：点球轮换可能偏重、可能偏轻、好球，不挪球；从头来清掉记号与记录', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, PuzzleTier.normal, 1);
      await _tool(tester, '做记号');
      await _tapBall(tester, 2);
      expect(find.bySemanticsLabel('3 号球，在桌上，记号：可能偏重'), findsOneWidget);
      await _tapBall(tester, 2);
      expect(find.bySemanticsLabel('3 号球，在桌上，记号：可能偏轻'), findsOneWidget);
      await _tapBall(tester, 2);
      expect(find.bySemanticsLabel('3 号球，在桌上，记号：好球'), findsOneWidget);
      await _tapBall(tester, 2);
      expect(find.bySemanticsLabel('3 号球，在桌上'), findsOneWidget);
      await _tapBall(tester, 2);
      await _weigh(tester, const BalanceWeighing([0, 1, 2, 3], [4, 5, 6, 7]));
      expect(find.bySemanticsLabel('3 号球，在桌上，记号：可能偏重'), findsOneWidget);
      expect(find.textContaining('称了 1/3 次'), findsOneWidget);
      await tester.tap(find.byTooltip('更多操作'));
      await _frames(tester, 400);
      await tester.tap(find.text('这一题从头来'));
      await _frames(tester, 400);
      expect(find.bySemanticsLabel('3 号球，在桌上'), findsOneWidget);
      expect(find.textContaining('称了 0/3 次'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^第 1 次')), findsNothing);
      semantics.dispose();
    });

    testWidgets('已知轻重的题做记号只记好球', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, PuzzleTier.entry, 2);
      await _tool(tester, '做记号');
      await _tapBall(tester, 0);
      expect(find.bySemanticsLabel('1 号球，在桌上，记号：好球'), findsOneWidget);
      await _tapBall(tester, 0);
      expect(find.bySemanticsLabel('1 号球，在桌上'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('减少动画：称了天平直接斜到位，停一会儿球直接回到桌上', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _open(tester, PuzzleTier.normal, 2);
      await _tapBall(tester, 0);
      await _tool(tester, '放右盘');
      await _tapBall(tester, 1);
      final onPan = tester.getCenter(_ball(0));
      await _button(tester, '称一下');
      await tester.pump();
      await tester.pump();
      final tilted = tester.getCenter(_ball(0));
      // 天平只在倾斜（不是平衡）时盘才上下动；不管哪种，都是直接到位、之后不再动。
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getCenter(_ball(0)), tilted);
      expect(find.bySemanticsLabel('1 号球，在左盘'), findsOneWidget);
      final puzzle = _rules.generate(2, PuzzleTier.normal).puzzle;
      final tilt = balanceRespond(puzzle, balanceStart(puzzle), 1, 2, 0);
      if (tilt == BalanceTilt.left) expect(tilted.dy, greaterThan(onPan.dy));
      if (tilt == BalanceTilt.right) expect(tilted.dy, lessThan(onPan.dy));
      await tester.pump(const Duration(milliseconds: 950));
      await tester.pump();
      expect(find.bySemanticsLabel('1 号球，在桌上'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('16 个球在 360 宽、1.3 倍字号下放得下：触区至少 48、不出界、两盘各放满 8 个不重叠', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(720, 1400);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      // 简单种子 3 是 16 个已知偏轻称 3 次。
      await _open(tester, PuzzleTier.easy, 3);
      expect(find.text('16 个球，最多称 3 次'), findsOneWidget);
      for (var ball = 0; ball < 16; ball++) {
        await tester.ensureVisible(_ball(ball));
        final rect = tester.getRect(_ball(ball));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(360));
      }
      for (var ball = 0; ball < 8; ball++) {
        await _tapBall(tester, ball);
      }
      // 一边最多 8 个：第 9 个被拒。
      await _tapBall(tester, 8);
      expect(find.text('一边最多放 8 个'), findsOneWidget);
      await _tool(tester, '放右盘');
      for (var ball = 8; ball < 16; ball++) {
        await _tapBall(tester, ball);
      }
      await tester.ensureVisible(_ball(0));
      await tester.pump();
      final rects = [for (var ball = 0; ball < 16; ball++) tester.getRect(_ball(ball))];
      for (final (index, rect) in rects.indexed) {
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(360));
        for (final other in rects.skip(index + 1)) {
          expect(rect.overlaps(other.deflate(1)), isFalse, reason: '$rect $other');
        }
      }
      semantics.dispose();
    });
  });
}
