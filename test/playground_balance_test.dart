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

BalancePuzzle _puzzle(int balls, int weighings, {bool knownHeavy = false, bool direction = false, int seed = 0}) =>
    BalancePuzzle(balls: balls, weighings: weighings, knownHeavy: knownHeavy, direction: direction, seed: seed);

// 物理上：假球是 ball、偏重 heavy 时这次称的结果。
BalanceTilt _physical(int ball, bool heavy, List<int> left, List<int> right) {
  if (left.contains(ball)) return heavy ? BalanceTilt.left : BalanceTilt.right;
  if (right.contains(ball)) return heavy ? BalanceTilt.right : BalanceTilt.left;
  return BalanceTilt.level;
}

// 每类球有几个：两向都可能、只可能偏重、只可能偏轻、确定是好球。
(int, int, int, int) _counts(BalancePuzzle puzzle, BalanceSuspects suspects) {
  final both = balanceBits(suspects.heavy & suspects.light);
  final heavy = balanceBits(suspects.heavy & ~suspects.light), light = balanceBits(suspects.light & ~suspects.heavy);
  return (both, heavy, light, puzzle.balls - both - heavy - light);
}

// 测试自己的一份极小极大（按每类球的个数，左右盘的好球个数全部枚举，不借规则文件里的剪枝）：rounds 次内不管秤怎么答都分得清。
final _memo = <String, bool>{};
bool _canSolve((int, int, int, int) state, int rounds, bool direction) {
  final (u, h, l, g) = state;
  if ((direction ? 2 * u + h + l : u + h + l) <= 1) return true;
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
                      (0, uL + hL, uR + lR),
                      (0, uR + hR, uL + lL),
                      (u - uL - uR, h - hL - hR, l - lL - lR),
                    ];
                    if (outcomes.every((next) {
                      final (a, b, c) = next;
                      return a + b + c == 0 || _canSolve((a, b, c, total - a - b - c), rounds - 1, direction);
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

// 还要称几次才分得清（数到 remaining + 1 为止）。
int _needed((int, int, int, int) state, int remaining, bool direction) {
  for (var rounds = 0; rounds <= remaining; rounds++) {
    if (_canSolve(state, rounds, direction)) return rounds;
  }
  return remaining + 1;
}

// 随机挑一次合规的称法：每边 1 到一半个球。
BalanceWeighing _randomWeighing(PuzzleRandom random, int balls) {
  final order = [for (var ball = 0; ball < balls; ball++) ball];
  random.shuffle(order);
  final size = 1 + random.nextInt(balls ~/ 2);
  return BalanceWeighing(order.take(size).toList()..sort(), order.skip(size).take(size).toList()..sort());
}

const _tiers = {
  PuzzleTier.entry: (9, 2, true, false),
  PuzzleTier.easy: (9, 3, false, false),
  PuzzleTier.normal: (12, 3, false, false),
  PuzzleTier.hard: (12, 3, false, true),
  PuzzleTier.expert: (13, 3, false, false),
};

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；动画按固定时长推进。
Future<void> _frames(WidgetTester tester, int millis) async {
  for (var elapsed = 0; elapsed < millis; elapsed += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder _ball(int ball) => find.bySemanticsLabel(RegExp('^${ball + 1} 号球，'));

Future<void> _tapBall(WidgetTester tester, int ball) async {
  await tester.ensureVisible(_ball(ball));
  await tester.pump();
  await tester.tap(_ball(ball));
  await _frames(tester, 260);
}

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
Future<void> _weigh(WidgetTester tester, BalanceWeighing weighing) async {
  await _tool(tester, '放左盘');
  for (final ball in weighing.left) {
    await _tapBall(tester, ball);
  }
  await _tool(tester, '放右盘');
  for (final ball in weighing.right) {
    await _tapBall(tester, ball);
  }
  await _button(tester, '称一下');
  await _frames(tester, 1800);
}

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
        final draw = _rules.generate(0, tier);
        _rules.difficulty(draw.puzzle);
        // 以前的游戏单题最慢在 100ms 量级；这里按类数搜，冷启动也只要几毫秒，留足 CI 的余量。
        expect(watch.elapsedMilliseconds, lessThan(300), reason: '$tier');
      }
      final watch = Stopwatch()..start();
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 20; seed++) {
          _rules.difficulty(_rules.generate(seed, tier).puzzle);
        }
      }
      expect(watch.elapsedMilliseconds, lessThan(1500));
    });

    test('求解器：每档在给定次数内一定找得出、少一次就不行，几个经典结论也对（与测试里另写的极小极大一致）', () {
      for (final MapEntry(key: tier, value: (balls, weighings, knownHeavy, direction)) in _tiers.entries) {
        final puzzle = _rules.generate(3, tier).puzzle;
        expect((puzzle.balls, puzzle.weighings, puzzle.knownHeavy, puzzle.direction), (balls, weighings, knownHeavy, direction), reason: '$tier');
        expect(balanceSolvable(puzzle), isTrue, reason: '$tier');
        expect(balanceSolvable(_puzzle(balls, weighings - 1, knownHeavy: knownHeavy, direction: direction)), isFalse, reason: '$tier');
      }
      // 已知偏重：3^k 个；不知轻重只需找出：(3^k − 1) / 2 个；还要说轻重：(3^k − 3) / 2 个（都没有额外的标准球）。
      final cases = <(int, int, bool, bool, bool)>[
        (9, 2, true, false, true),
        (10, 2, true, false, false),
        (4, 2, false, false, true),
        (5, 2, false, false, false),
        (3, 2, false, true, true),
        (4, 2, false, true, false),
        (13, 3, false, false, true),
        (12, 3, false, true, true),
        (13, 3, false, true, false),
        (3, 1, true, false, true),
        (3, 1, false, false, false),
      ];
      for (final (balls, weighings, knownHeavy, direction, expected) in cases) {
        final puzzle = _puzzle(balls, weighings, knownHeavy: knownHeavy, direction: direction);
        final reason = '$balls 球 $weighings 次 已知偏重=$knownHeavy 说轻重=$direction';
        expect(balanceSolvable(puzzle), expected, reason: reason);
        final start = _counts(puzzle, balanceStart(puzzle));
        expect(_canSolve(start, weighings, direction), expected, reason: reason);
      }
    });

    test('秤的回答：和之前全部结果都对得上，留下的候选恰好是物理上说得通的那些，候选从不为空', () {
      final random = PuzzleRandom(77);
      for (final MapEntry(key: tier, value: (_, weighings, _, _)) in _tiers.entries) {
        for (var round = 0; round < 40; round++) {
          final puzzle = _rules.generate(round, tier).puzzle;
          final plan = [for (var index = 0; index < weighings; index++) _randomWeighing(random, puzzle.balls)];
          final replay = balanceReplay(puzzle, plan)!;
          final suspects = replay.suspects;
          expect(suspects.heavy | suspects.light, isNot(0));
          for (var ball = 0; ball < puzzle.balls; ball++) {
            for (final heavy in [true, false]) {
              final fits = !(puzzle.knownHeavy && !heavy) && plan.indexed.every((entry) => _physical(ball, heavy, entry.$2.left, entry.$2.right) == replay.tilts[entry.$1]);
              expect(((heavy ? suspects.heavy : suspects.light) >> ball) & 1 == 1, fits, reason: '$tier $round $ball $heavy');
            }
          }
        }
      }
    });

    test('秤挑剩下还要称最多次的结果（另写的极小极大核对每一次）：称错一步一定挑到分不清的那支', () {
      final random = PuzzleRandom(5);
      for (final MapEntry(key: tier, value: (_, weighings, _, direction)) in _tiers.entries) {
        for (var round = 0; round < 30; round++) {
          final puzzle = _rules.generate(round, tier).puzzle;
          var suspects = balanceStart(puzzle);
          for (var index = 0; index < weighings; index++) {
            final weighing = _randomWeighing(random, puzzle.balls);
            final (left, right) = (balanceMask(weighing.left), balanceMask(weighing.right));
            final outcomes = balanceSplit(suspects, left, right);
            final keys = [
              for (final next in outcomes)
                if (next.heavy | next.light == 0) -1 else _needed(_counts(puzzle, next), weighings - index - 1, direction),
            ];
            final tilt = balanceRespond(puzzle, suspects, left, right, index);
            expect(keys[tilt.index], keys.reduce(math.max), reason: '$tier $round $index $keys');
            suspects = outcomes[tilt.index];
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

    test('穷举：按类数走遍每一种称法，平局不论按哪个种子挑、都按玩家最有利的算，玩家赢得了的局面也恰好是极小极大下来得及的（靠运气赢不了）', () {
      // 平局只看种子与第几次：同一个局面、同一种称法换 24 个种子，秤可能给的回答都出现了（漏掉一种的概率不到万分之一）。
      const seeds = 24;
      for (final MapEntry(key: tier, value: (balls, weighings, knownHeavy, direction)) in _tiers.entries) {
        final puzzles = [for (var seed = 0; seed < seeds; seed++) _puzzle(balls, weighings, knownHeavy: knownHeavy, direction: direction, seed: seed)];
        final puzzle = puzzles.first;
        final memo = <String, bool>{};
        var visited = 0;
        // 玩家赢得了：有一种称法，秤可能给的每一种回答里只要有一种接着赢得了就算（平局全按玩家最有利的挑）。
        bool win(BalanceSuspects suspects, int index) {
          final state = _counts(puzzle, suspects);
          final key = '$state $index';
          if (memo[key] case final known?) return known;
          visited++;
          final (u, h, l, g) = state;
          var result = (direction ? 2 * u + h + l : u + h + l) <= 1;
          if (!result && index < weighings) {
            // 每类按编号从小取：两向都可能、只可能偏重、只可能偏轻、好球。
            final both = balanceMembers(suspects.heavy & suspects.light);
            final heavy = balanceMembers(suspects.heavy & ~suspects.light), light = balanceMembers(suspects.light & ~suspects.heavy);
            final good = balanceMembers(puzzle.everyone & ~(suspects.heavy | suspects.light));
            search:
            for (var uL = 0; uL <= u; uL++) {
              for (var uR = 0; uR <= u - uL; uR++) {
                for (var hL = 0; hL <= h; hL++) {
                  for (var hR = 0; hR <= h - hL; hR++) {
                    for (var lL = 0; lL <= l; lL++) {
                      for (var lR = 0; lR <= l - lL; lR++) {
                        final (sizeLeft, sizeRight) = (uL + hL + lL, uR + hR + lR);
                        final (gL, gR) = (math.max(0, sizeRight - sizeLeft), math.max(0, sizeLeft - sizeRight));
                        if (sizeLeft + sizeRight == 0 || gL + gR > g) continue;
                        final left = [...both.take(uL), ...heavy.take(hL), ...light.take(lL), ...good.take(gL)];
                        final right = [...both.skip(uL).take(uR), ...heavy.skip(hL).take(hR), ...light.skip(lL).take(lR), ...good.skip(gL).take(gR)];
                        final (leftMask, rightMask) = (balanceMask(left), balanceMask(right));
                        final answers = {for (final each in puzzles) balanceRespond(each, suspects, leftMask, rightMask, index)};
                        final outcomes = balanceSplit(suspects, leftMask, rightMask);
                        if (answers.any((tilt) => win(outcomes[tilt.index], index + 1))) {
                          result = true;
                          break search;
                        }
                      }
                    }
                  }
                }
              }
            }
          }
          expect(result, _canSolve(state, weighings - index, direction), reason: '$tier $state 第 $index 次前');
          return memo[key] = result;
        }

        expect(win(balanceStart(puzzle), 0), isTrue, reason: '$tier');
        expect(visited, greaterThan(1), reason: '$tier');
      }
    });

    test('每档 20 道：参考解按规则判定通过、次数不超、最后候选恰好是指认的那个；同一个种子出同一道题', () {
      for (final MapEntry(key: tier, value: (_, weighings, _, direction)) in _tiers.entries) {
        for (var seed = 0; seed < 20; seed++) {
          final draw = _rules.generate(seed, tier);
          final solution = draw.solution;
          expect(_rules.solved(draw.puzzle, solution), isTrue, reason: '$tier $seed');
          expect(solution.weighings.length, lessThanOrEqualTo(weighings));
          expect(solution.heavy != null, direction);
          final suspects = balanceReplay(draw.puzzle, solution.weighings)!.suspects;
          expect(balanceVerdict(draw.puzzle, suspects, solution.ball, solution.heavy), BalanceVerdict.solved);
        }
      }
      expect(jsonEncode(_rules.encodeAnswer(_rules.generate(4, PuzzleTier.expert).solution)), jsonEncode(_rules.encodeAnswer(_rules.generate(4, PuzzleTier.expert).solution)));
    });

    test('违规不算解开：超次数、两边球数不等、有一边空、同一个球两边都放、编号越界、还确定不了就指认、指认的不是候选、轻重说错或该说没说', () {
      final draw = _rules.generate(2, PuzzleTier.hard);
      final puzzle = draw.puzzle, solution = draw.solution;
      BalanceAnswer variant({List<BalanceWeighing>? weighings, int? ball, bool? heavy, bool keepHeavy = true}) =>
          BalanceAnswer(weighings ?? solution.weighings, ball ?? solution.ball, keepHeavy ? heavy ?? solution.heavy : null);
      expect(_rules.solved(puzzle, solution), isTrue);
      expect(_rules.solved(puzzle, variant(weighings: [...solution.weighings, const BalanceWeighing([0], [1])])), isFalse);
      expect(_rules.solved(puzzle, variant(weighings: [const BalanceWeighing([0, 1], [2]), ...solution.weighings.skip(1)])), isFalse);
      expect(_rules.solved(puzzle, variant(weighings: [const BalanceWeighing([], [2]), ...solution.weighings.skip(1)])), isFalse);
      expect(_rules.solved(puzzle, variant(weighings: [const BalanceWeighing([0, 1], [1, 2]), ...solution.weighings.skip(1)])), isFalse);
      expect(_rules.solved(puzzle, variant(weighings: [const BalanceWeighing([0, 1], [2, 12]), ...solution.weighings.skip(1)])), isFalse);
      expect(_rules.solved(puzzle, variant(weighings: solution.weighings.take(2).toList())), isFalse);
      expect(_rules.solved(puzzle, variant(ball: (solution.ball + 1) % puzzle.balls)), isFalse);
      expect(_rules.solved(puzzle, variant(heavy: !solution.heavy!)), isFalse);
      expect(_rules.solved(puzzle, variant(keepHeavy: false)), isFalse);
      // 只需找出的题不收轻重。
      final find = _rules.generate(2, PuzzleTier.normal);
      expect(_rules.solved(find.puzzle, find.solution), isTrue);
      expect(_rules.solved(find.puzzle, BalanceAnswer(find.solution.weighings, find.solution.ball, true)), isFalse);
      // 指认的判定：一开始谁都还确定不了；参考解称完后，别的球都对不上。
      final start = balanceStart(puzzle);
      expect(balanceVerdict(puzzle, start, 0, true), BalanceVerdict.undetermined);
      final suspects = balanceReplay(puzzle, solution.weighings)!.suspects;
      expect(balanceVerdict(puzzle, suspects, (solution.ball + 1) % puzzle.balls, true), BalanceVerdict.contradicts);
      expect(balanceVerdict(puzzle, suspects, solution.ball, !solution.heavy!), BalanceVerdict.contradicts);
      // 只剩一个球、还不知道轻重：要说轻重的题还确定不了，只需找出的题已经找出来了。
      const pair = (heavy: 1 << 5, light: 1 << 5);
      expect(balanceVerdict(puzzle, pair, 5, true), BalanceVerdict.undetermined);
      expect(balanceVerdict(puzzle, pair, 5, false), BalanceVerdict.undetermined);
      expect(balanceVerdict(find.puzzle, pair, 5, null), BalanceVerdict.solved);
      expect(balanceFault(puzzle, [0, 1], [2]), BalanceFault.uneven);
      expect(balanceFault(puzzle, [0], []), BalanceFault.empty);
      expect(balanceFault(puzzle, [0, 0], [1, 2]), BalanceFault.invalid);
      expect(balanceFault(puzzle, [0], [1]), isNull);
    });

    test('难度分：同档同分、逐档上升（1、3、8、9、10），解不开的按 10 分', () {
      final expected = {PuzzleTier.entry: 1, PuzzleTier.easy: 3, PuzzleTier.normal: 8, PuzzleTier.hard: 9, PuzzleTier.expert: 10};
      for (final tier in PuzzleTier.values) {
        final scores = {for (var seed = 0; seed < 20; seed++) _rules.difficulty(_rules.generate(seed, tier).puzzle)};
        expect(scores, {expected[tier]}, reason: '$tier');
      }
      expect(_rules.difficulty(_puzzle(13, 3, direction: true)), 10);
    });

    test('编解码往返，坏输入抛 FormatException', () {
      for (final tier in PuzzleTier.values) {
        final draw = _rules.generate(7, tier);
        final json = jsonDecode(jsonEncode(_rules.encodePuzzle(draw.puzzle)));
        final puzzle = _rules.decodePuzzle(json);
        expect(_rules.encodePuzzle(puzzle), _rules.encodePuzzle(draw.puzzle));
        final answer = _rules.decodeAnswer(jsonDecode(jsonEncode(_rules.encodeAnswer(draw.solution))));
        expect(_rules.solved(puzzle, answer), isTrue);
        expect(answer.heavy, draw.solution.heavy);
      }
      const good = {'balls': 12, 'weighings': 3, 'knownHeavy': false, 'direction': true, 'seed': 5};
      expect(_rules.decodePuzzle(good).direction, isTrue);
      for (final bad in <Object?>[
        null,
        '12',
        {...good, 'balls': 2},
        {...good, 'balls': 14},
        {...good, 'balls': '12'},
        {...good, 'weighings': 0},
        {...good, 'weighings': 4},
        {...good, 'seed': -1},
        {...good, 'seed': 0x100000000},
        {...good, 'knownHeavy': 1},
        {...good, 'direction': null},
        {...good, 'knownHeavy': true, 'direction': true},
        // 在限定次数内找不出：13 个球称 3 次还要说轻重、10 个已知偏重称 2 次。
        {...good, 'balls': 13},
        {'balls': 10, 'weighings': 2, 'knownHeavy': true, 'direction': false, 'seed': 0},
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      expect(_rules.decodeAnswer({'weighings': <Object>[], 'ball': 3}).heavy, isNull);
      for (final bad in <Object?>[
        null,
        [1],
        {'weighings': <Object>[], 'ball': 13},
        {'weighings': <Object>[], 'ball': '1'},
        {'weighings': <Object>[], 'ball': 1, 'heavy': 1},
        {'weighings': [[[0], [1]], [[0], [1]], [[0], [1]], [[0], [1]]], 'ball': 1},
        {'weighings': [[[0], [0]]], 'ball': 1},
        {'weighings': [[[0, 0], [1, 2]]], 'ball': 1},
        {'weighings': [[[0], [1], [2]]], 'ball': 1},
        {'weighings': [[[0], [13]]], 'ball': 1},
        {'weighings': [[[0], '1']], 'ball': 1},
        {'weighings': '0|1', 'ball': 1},
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
      await _open(tester, PuzzleTier.entry, 3);
      final puzzle = _rules.generate(3, PuzzleTier.entry).puzzle;
      expect(find.text('9 个球，最多称 2 次'), findsOneWidget);
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
      expect(find.text('两边的球数要一样：左边 2 个，右边 1 个'), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.heavyImpact']);
      expect(find.textContaining('称了 0/2 次'), findsOneWidget);

      // 点盘里的球拿回桌上是一步正常操作：过时的提示马上收起。
      await _tapBall(tester, 1);
      await _frames(tester, 400);
      expect(find.text('两边的球数要一样：左边 2 个，右边 1 个'), findsNothing);
      expect(find.bySemanticsLabel('2 号球，在桌上'), findsOneWidget);

      // 1 对 3：称了，记一行，球回到桌上。
      await _button(tester, '称一下');
      await tester.pump();
      final tilt = balanceRespond(puzzle, balanceStart(puzzle), balanceMask([0]), balanceMask([2]), 0);
      final result = switch (tilt) {
        BalanceTilt.left => '左边重',
        BalanceTilt.right => '右边重',
        BalanceTilt.level => '平衡',
      };
      expect(find.bySemanticsLabel('第 1 次：左盘 1 号，右盘 3 号，$result'), findsOneWidget);
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
      await _open(tester, PuzzleTier.entry, 4);
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
      final puzzle = _rules.generate(4, PuzzleTier.entry).puzzle;
      final suspects = balanceReplay(puzzle, const [BalanceWeighing([0], [1]), BalanceWeighing([2], [3])])!.suspects;
      final candidate = balanceMembers(suspects.heavy).first;
      await _button(tester, '指认');
      await _frames(tester, 300);
      await _tapBall(tester, candidate);
      await _button(tester, '确认');
      await _frames(tester, 300);
      expect(find.text('还确定不了。2 次都称过了，可以从⋯里「这一题从头来」'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '确认'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('按参考称法走完：指认那个球解开，球鼓一下再弹新纪录，可换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = await _open(tester, PuzzleTier.entry, 6);
      final solution = _rules.generate(6, PuzzleTier.entry).solution;
      for (final weighing in solution.weighings) {
        await _weigh(tester, weighing);
      }
      await _button(tester, '指认');
      await _frames(tester, 300);
      // 先指认一个已经排除的：对不上，记一次指认错。
      final wrong = (solution.ball + 1) % 9;
      await _tapBall(tester, wrong);
      await _button(tester, '确认');
      await _frames(tester, 300);
      expect(find.text('${wrong + 1} 号和称的结果对不上'), findsOneWidget);
      // 次数用完了，留在指认里，直接换一个。
      expect(find.widgetWithText(FilledButton, '确认'), findsOneWidget);
      await _tapBall(tester, solution.ball);
      await _button(tester, '确认');
      await tester.pump();
      expect(find.text('新纪录'), findsNothing);
      await _frames(tester, 300);
      expect(find.bySemanticsLabel('${solution.ball + 1} 号球，在桌上，就是它'), findsOneWidget);
      await _frames(tester, 900);
      expect(find.text('新纪录'), findsOneWidget);
      // 结果说明行按「 · 」分项排，各项分开找。
      expect(find.textContaining(RegExp('^称 2 次')), findsOneWidget);
      expect(find.textContaining('指认错 1 次'), findsOneWidget);
      expect(store.best('balance', PuzzleTier.entry)!.moves, 2);
      await tester.tap(find.text('换到简单'));
      await _frames(tester, 600);
      expect(store.tierOf('balance'), PuzzleTier.easy);
      expect(find.text('9 个球，最多称 3 次'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('要说轻重的档：选偏重或偏轻才能确认，说对了才解开', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, PuzzleTier.hard, 8);
      final solution = _rules.generate(8, PuzzleTier.hard).solution;
      for (final weighing in solution.weighings) {
        await _weigh(tester, weighing);
      }
      await _button(tester, '指认');
      await _frames(tester, 300);
      await _tapBall(tester, solution.ball);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认')).onPressed, isNull);
      await tester.tap(find.text(solution.heavy! ? '偏轻' : '偏重'));
      await _frames(tester, 300);
      await _button(tester, '确认');
      await _frames(tester, 300);
      expect(find.text('${solution.ball + 1} 号${solution.heavy! ? '偏轻' : '偏重'}和称的结果对不上'), findsOneWidget);
      await _tapBall(tester, solution.ball);
      await tester.tap(find.text(solution.heavy! ? '偏重' : '偏轻'));
      await _frames(tester, 300);
      await _button(tester, '确认');
      await _frames(tester, 1500);
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
      final tilt = balanceRespond(_rules.generate(2, PuzzleTier.normal).puzzle, balanceStart(_rules.generate(2, PuzzleTier.normal).puzzle), 1, 2, 0);
      if (tilt == BalanceTilt.left) expect(tilted.dy, greaterThan(onPan.dy));
      if (tilt == BalanceTilt.right) expect(tilted.dy, lessThan(onPan.dy));
      await tester.pump(const Duration(milliseconds: 950));
      await tester.pump();
      expect(find.bySemanticsLabel('1 号球，在桌上'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('专家档 13 个球在 360 宽、1.3 倍字号下放得下：触区至少 48、不出界、两盘各放满 6 个不重叠', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(720, 1400);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _open(tester, PuzzleTier.expert, 1);
      for (var ball = 0; ball < 13; ball++) {
        final rect = tester.getRect(_ball(ball));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(360));
      }
      for (var ball = 0; ball < 6; ball++) {
        await _tapBall(tester, ball);
      }
      // 一边最多 6 个：第 7 个被拒。
      await _tapBall(tester, 6);
      expect(find.text('一边最多放 6 个'), findsOneWidget);
      await _tool(tester, '放右盘');
      for (var ball = 6; ball < 12; ball++) {
        await _tapBall(tester, ball);
      }
      final rects = [for (var ball = 0; ball < 12; ball++) tester.getRect(_ball(ball))];
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
