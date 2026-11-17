import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_rules.dart';
import 'package:superxd/playground/puzzle/nonogram/nonogram_rules.dart';
import 'package:superxd/playground/puzzle/pour/pour_rules.dart';
import 'package:superxd/playground/puzzle/schulte/schulte_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';

void main() {
  // 预计用时做标尺（人工决策见 puzzle_rules.dart 文件头）：难度分按预计用时取对数，跨游戏可比；每个游戏的预计用时随档不降。
  group('预计用时与难度分', () {
    test('难度分按预计用时取对数：25 秒 2、1 分钟 4、2 分钟 5、5 分钟 7、10 分钟 8、20 分钟起 10', () {
      expect([for (final seconds in [5, 10, 25, 60, 120, 300, 600, 1200, 99999]) puzzleDifficulty(seconds)], [1, 1, 2, 4, 5, 7, 8, 10, 10]);
      expect(puzzlePace(1, base: 30, growth: 1.5), 30);
      expect(puzzlePace(3, base: 30, growth: 1.5), 68);
    });

    test('每个游戏的预计用时随档不降，难度分都在 1–10', () {
      final all = <String, PuzzleRules<Object?, Object?>>{...challengeRules, 'schulte': const SchulteRules(), 'pour': const PourRules()};
      for (final MapEntry(key: game, value: rules) in all.entries) {
        var previous = 0;
        for (final tier in PuzzleTier.values) {
          final seconds = <int>[];
          for (var seed = 0; seed < (game == 'pour' ? 3 : 5); seed++) {
            final puzzle = rules.generate(seed, tier).puzzle;
            seconds.add(rules.expectedSeconds(puzzle));
            expect(rules.difficulty(puzzle), inInclusiveRange(1, 10), reason: '$game $tier $seed');
          }
          seconds.sort();
          final median = seconds[seconds.length ~/ 2];
          expect(median, greaterThanOrEqualTo(previous), reason: '$game $tier');
          previous = median;
        }
      }
    });
  });

  group('可复现的随机数', () {
    test('同一个种子出同一串数，换种子不同', () {
      List<int> run(int seed) {
        final random = PuzzleRandom(seed);
        return [for (var index = 0; index < 8; index++) random.nextUint32()];
      }

      expect(run(42), run(42));
      expect(run(42), isNot(run(43)));
      // 钉住前几个值（按参考算法另用 Python 独立实现算出）：换语言实现（题库工具、服务器）要逐位对得上。
      expect(run(1).take(3), [2442144158, 3238099751, 3819917871]);
      expect(run(42).take(3), [2837322924, 544945897, 479756282]);
    });

    test('nextInt 落在范围里且大致均匀', () {
      final random = PuzzleRandom(7);
      final counts = List.filled(5, 0);
      for (var index = 0; index < 5000; index++) {
        counts[random.nextInt(5)]++;
      }
      for (final count in counts) {
        expect(count, inInclusiveRange(850, 1150));
      }
    });
  });

  group('汉诺塔', () {
    const rules = HanoiRules();
    HanoiPuzzle tower(int pegs, HanoiVariant variant, int disks, int from, int to) => HanoiPuzzle(pegs: pegs, variant: variant, start: List.filled(disks, from), goal: List.filled(disks, to));

    test('最少步数按公式核对：经典 2^n−1、四柱 Frame–Stewart、循环顺逆两向的递推、三柱相邻 3^n−1', () {
      for (var disks = 1; disks <= 7; disks++) {
        expect(hanoiMinMoves(tower(3, HanoiVariant.classic, disks, 0, 2)), (1 << disks) - 1, reason: '经典 $disks 盘');
      }
      // 四柱（Reve 问题）整叠搬：Frame–Stewart 数（四柱已证明是最优）。
      expect([for (var disks = 1; disks <= 8; disks++) hanoiMinMoves(tower(4, HanoiVariant.classic, disks, 0, 3))], [1, 3, 5, 9, 13, 17, 25, 33]);
      // 循环：顺着挪一格 Q(n) = 2R(n−1) + 1，逆着挪一格（等于顺着挪两格）R(n) = 2R(n−1) + Q(n−1) + 2。
      var forward = 1, backward = 2;
      for (var disks = 1; disks <= 5; disks++) {
        expect(hanoiMinMoves(tower(3, HanoiVariant.cyclic, disks, 0, 1)), forward, reason: '循环顺 $disks 盘');
        expect(hanoiMinMoves(tower(3, HanoiVariant.cyclic, disks, 0, 2)), backward, reason: '循环逆 $disks 盘');
        (forward, backward) = (2 * backward + 1, 2 * backward + forward + 2);
      }
      for (var disks = 1; disks <= 5; disks++) {
        expect(hanoiMinMoves(tower(3, HanoiVariant.adjacent, disks, 0, 2)), math.pow(3, disks) - 1, reason: '相邻 $disks 盘');
      }
      // 手算：最大的盘已在目标柱，只看剩下两个；两个盘子对调要绕第三根柱。
      expect(hanoiMinMoves(const HanoiPuzzle(pegs: 3, variant: HanoiVariant.classic, start: [0, 0, 2], goal: [2, 2, 2])), 3);
      expect(hanoiMinMoves(const HanoiPuzzle(pegs: 3, variant: HanoiVariant.classic, start: [0, 1], goal: [1, 0])), 3);
    });

    test('最少步数与测试另写的按叠放广度优先一致（随机局面、每种挪法）', () {
      final random = PuzzleRandom(77);
      for (final (pegs, variant) in [(3, HanoiVariant.classic), (3, HanoiVariant.cyclic), (3, HanoiVariant.adjacent), (4, HanoiVariant.classic), (4, HanoiVariant.adjacent), (4, HanoiVariant.cyclic)]) {
        for (var round = 0; round < 12; round++) {
          final disks = 2 + random.nextInt(3);
          final start = [for (var disk = 0; disk < disks; disk++) random.nextInt(pegs)];
          var goal = [for (var disk = 0; disk < disks; disk++) random.nextInt(pegs)];
          if (goal.join() == start.join()) goal = [for (final peg in start) (peg + 1) % pegs];
          final puzzle = HanoiPuzzle(pegs: pegs, variant: variant, start: start, goal: goal);
          expect(hanoiMinMoves(puzzle), _hanoiBrute(puzzle), reason: '$pegs $variant $start → $goal');
          expect(hanoiSolution(puzzle), hasLength(hanoiMinMoves(puzzle)));
          expect(rules.solved(puzzle, hanoiSolution(puzzle)), isTrue);
        }
      }
    });

    test('合法移动：相邻只到旁边、循环只顺着到下一根（最后一根回第一根），大盘不压小盘、空柱与界外不能挪', () {
      const adjacent = HanoiPuzzle(pegs: 4, variant: HanoiVariant.adjacent, start: [0, 1, 2, 3], goal: [3, 3, 3, 3]);
      expect([for (final (from, to) in [(0, 1), (1, 0), (1, 2), (2, 3), (3, 2)]) hanoiAllowed(adjacent, from, to)], everyElement(isTrue));
      expect([for (final (from, to) in [(0, 2), (0, 3), (3, 1), (1, 1), (0, 4)]) hanoiAllowed(adjacent, from, to)], everyElement(isFalse));
      const cyclic = HanoiPuzzle(pegs: 3, variant: HanoiVariant.cyclic, start: [0, 1, 2], goal: [2, 2, 2]);
      expect([hanoiAllowed(cyclic, 0, 1), hanoiAllowed(cyclic, 1, 2), hanoiAllowed(cyclic, 2, 0)], everyElement(isTrue));
      expect([hanoiAllowed(cyclic, 1, 0), hanoiAllowed(cyclic, 2, 1), hanoiAllowed(cyclic, 0, 2), hanoiAllowed(cyclic, 2, 3)], everyElement(isFalse));
      const four = HanoiPuzzle(pegs: 4, variant: HanoiVariant.cyclic, start: [0, 1, 2, 3], goal: [0, 0, 0, 0]);
      expect([hanoiAllowed(four, 3, 0), hanoiAllowed(four, 2, 3)], everyElement(isTrue));
      expect([hanoiAllowed(four, 2, 0), hanoiAllowed(four, 0, 3)], everyElement(isFalse));
      // 三柱经典：开局 0 号盘在第 1 根、1 号盘在第 2 根。
      const classic = HanoiPuzzle(pegs: 3, variant: HanoiVariant.classic, start: [0, 1], goal: [2, 2]);
      final stacks = hanoiStacks(3, classic.start);
      expect(hanoiLegal(classic, stacks, (from: 1, to: 0)), isFalse, reason: '大盘压小盘');
      expect(hanoiLegal(classic, stacks, (from: 2, to: 0)), isFalse, reason: '空柱');
      expect(hanoiLegal(classic, stacks, (from: 0, to: 3)), isFalse, reason: '三柱没有第 4 根');
      expect(hanoiLegal(classic, stacks, (from: 0, to: 1)), isTrue);
      expect(rules.solved(classic, [(from: 0, to: 1), (from: 1, to: 2)]), isFalse, reason: '0 号盘压在 1 号上后 1 号挪不动');
      expect(rules.solved(classic, [(from: 1, to: 2), (from: 0, to: 2)]), isTrue);
      expect(rules.solved(classic, [(from: 1, to: 2)]), isFalse, reason: '没摆完');
    });

    test('每档出的题：没解开，参考解是最少步数且判定解开；预计用时与难度分落在这一档，五档分段不重叠', () {
      const scores = {PuzzleTier.entry: 3, PuzzleTier.easy: 4, PuzzleTier.normal: 5, PuzzleTier.hard: 6, PuzzleTier.expert: 7};
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 24; seed++) {
          final draw = rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          expect(rules.solved(puzzle, const []), isFalse, reason: '$tier $seed');
          expect(draw.solution.length, hanoiMinMoves(puzzle));
          expect(rules.solved(puzzle, draw.solution), isTrue);
          expect(rules.difficulty(puzzle), scores[tier], reason: '$tier $seed ${rules.expectedSeconds(puzzle)} 秒');
          expect(rules.complexity(puzzle), inInclusiveRange(tier.index * 2 + 1, tier.index * 2 + 2), reason: '$tier $seed');
          expect(rules.fragment(puzzle, draw.solution), draw.solution.length);
          expect(rules.minimum(puzzle), draw.solution.length);
        }
      }
      expect(rules.encodePuzzle(rules.generate(3, PuzzleTier.hard).puzzle), rules.encodePuzzle(rules.generate(3, PuzzleTier.hard).puzzle));
    });

    test('随机开局与目标：每档题几乎不重样、高四档两种题都出、有一根柱的目标也有摆样子的目标；变体都按档递进', () {
      const kinds = {
        PuzzleTier.entry: {'3classic4'},
        PuzzleTier.easy: {'3classic5', '4classic7'},
        PuzzleTier.normal: {'3cyclic4', '4classic8'},
        PuzzleTier.hard: {'3cyclic5', '4adjacent6'},
        PuzzleTier.expert: {'4cyclic6', '4adjacent7'},
      };
      for (final tier in PuzzleTier.values) {
        final seen = <String>{}, found = <String>{};
        var towers = 0;
        for (var seed = 0; seed < 60; seed++) {
          final puzzle = rules.generate(seed * 131 + 7, tier).puzzle;
          seen.add(jsonEncode(rules.encodePuzzle(puzzle)));
          found.add('${puzzle.pegs}${puzzle.variant.name}${puzzle.disks}');
          if (puzzle.tower != null) towers++;
        }
        expect(seen.length, greaterThanOrEqualTo(54), reason: '$tier 60 道里不重样的');
        expect(found, kinds[tier], reason: '$tier');
        expect(towers, inInclusiveRange(5, 30), reason: '$tier 目标是一根柱的');
      }
    });

    test('变体真起作用：去掉方向限制最少步数变少，拿掉空着的第四根柱最少步数变多', () {
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 24; seed++) {
          final puzzle = rules.generate(seed, tier).puzzle;
          final least = hanoiMinMoves(puzzle), looser = hanoiLooser(puzzle);
          switch ((puzzle.pegs, puzzle.variant)) {
            case (3, HanoiVariant.classic):
              expect(looser, isNull);
            case (_, HanoiVariant.classic):
              expect(looser, greaterThan(least), reason: '$tier $seed 第四根柱要用得上');
            case _:
              expect(looser, lessThan(least), reason: '$tier $seed 方向限制要让路变长');
          }
        }
      }
    });

    test('出题与判定耗时：出题最慢一次不超过 200 毫秒，判定满 4096 步的答案与求最少步数不超过 100 毫秒', () {
      var slowest = Duration.zero;
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 20; seed++) {
          final watch = Stopwatch()..start();
          rules.generate(seed * 7919, tier);
          if (watch.elapsed > slowest) slowest = watch.elapsed;
        }
      }
      expect(slowest, lessThan(const Duration(milliseconds: 200)));
      final reve = rules.generate(2, PuzzleTier.normal).puzzle;
      expect(reve.disks, 8);
      final watch = Stopwatch()..start();
      final least = hanoiMinMoves(reve);
      // 来回挪最小的盘子凑满上限：每一步都要重放。
      final idle = (hanoiMaxMoves - least) ~/ 2 * 2, home = reve.start[0], away = (reve.start[0] + 1) % reve.pegs;
      final long = [for (var index = 0; index < idle; index++) index.isEven ? (from: home, to: away) : (from: away, to: home), ...hanoiSolution(reve)];
      expect(long.length, lessThanOrEqualTo(hanoiMaxMoves));
      final passed = rules.solved(reve, long);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 100)));
      expect(passed, isTrue);
    });

    // [人工决策-2026-11-17 14:17:05]（见 challenge_rules.dart）：挑战高档的汉诺塔走到最少步数的 1.2 倍以内（含、向下取整）算过，其他游戏正好最少。
    test('挑战高档的步数上限：最少步数的 1.2 倍向下取整，其他游戏正好最少', () {
      expect([for (final least in [1, 5, 7, 60, 63, 84]) rules.stepLimit(least)], [1, 6, 8, 72, 75, 100]);
      expect(challengeStepLimit('hanoi', 60), 72);
      expect([for (final game in challengeRules.keys.where((game) => game != 'hanoi')) challengeStepLimit(game, 60)], everyElement(60));
    });

    test('编解码往返，坏输入抛 FormatException', () {
      final draw = rules.generate(5, PuzzleTier.expert);
      final puzzle = rules.decodePuzzle(jsonDecode(jsonEncode(rules.encodePuzzle(draw.puzzle))));
      expect([puzzle.pegs, puzzle.variant, puzzle.start, puzzle.goal], [draw.puzzle.pegs, draw.puzzle.variant, draw.puzzle.start, draw.puzzle.goal]);
      expect(rules.solved(puzzle, rules.decodeAnswer(jsonDecode(jsonEncode(rules.encodeAnswer(draw.solution))))), isTrue);
      expect(rules.encodeAnswer([(from: 3, to: 0), (from: 0, to: 1)]), [12, 1]);
      Map<String, Object> sample([Map<String, Object> change = const {}]) => {'pegs': 3, 'variant': 0, 'start': [0, 0, 1], 'goal': [2, 2, 2], ...change};
      expect(rules.decodePuzzle(sample()).goal, [2, 2, 2]);
      for (final bad in [
        {'pegs': 5},
        {'pegs': 2},
        {'variant': 3},
        {'start': [0, 0]},
        {'start': [0, 0, 3]},
        {'goal': [2, 2, 3]},
        {'start': <int>[], 'goal': <int>[]},
        {'goal': [0, 0, 1]},
        {'start': List.filled(9, 0), 'goal': List.filled(9, 1)},
      ]) {
        expect(() => rules.decodePuzzle(sample(bad)), throwsFormatException, reason: '$bad');
      }
      expect(() => rules.decodePuzzle({'disks': 3, 'start': [0, 0, 0], 'target': 2}), throwsFormatException, reason: '第 1 版的写法');
      expect(() => rules.decodeAnswer([16]), throwsFormatException);
      expect(() => rules.decodeAnswer([-1]), throwsFormatException);
      expect(() => rules.decodeAnswer('0'), throwsFormatException);
      expect(() => rules.decodeAnswer(List.filled(hanoiMaxMoves + 1, 1)), throwsFormatException);
      // 编码里的 0、5（原地不动）解码得出，判定时不合规。
      expect(rules.solved(rules.decodePuzzle(sample()), rules.decodeAnswer([0])), isFalse);
    });
  });

  group('数织', () {
    const rules = NonogramRules();
    const filled = NonogramCell.filled, empty = NonogramCell.empty, unknown = NonogramCell.unknown;

    test('一行的推理：重叠部分定为涂，排不下判矛盾', () {
      // 长 5 的行放一段 4：中间 3 格必涂。
      expect(nonogramSolveLine([4], List.filled(5, unknown)), [unknown, filled, filled, filled, unknown]);
      // 3 1 正好占满 5 格。
      expect(nonogramSolveLine([3, 1], List.filled(5, unknown)), [filled, filled, filled, empty, filled]);
      // 已知第一格为空，段 4 只能放在后四格。
      expect(nonogramSolveLine([4], [empty, unknown, unknown, unknown, unknown]), [empty, filled, filled, filled, filled]);
      expect(nonogramSolveLine([3, 2], List.filled(5, unknown)), isNull);
      expect(nonogramSolveLine([], [unknown, filled]), isNull);
      expect(nonogramSolveLine([], [unknown, unknown]), [empty, empty]);
    });

    test('每档出的题逐行推理能唯一解开，参考解判定为解开', () {
      final watch = Stopwatch()..start();
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 10; seed++) {
          final draw = rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          expect(nonogramLineSolve(puzzle), isNotNull, reason: '$tier $seed');
          expect(rules.solved(puzzle, draw.solution), isTrue);
          expect(rules.solved(puzzle, List.filled(puzzle.width * puzzle.height, false)), isFalse);
          expect(rules.difficulty(puzzle), inInclusiveRange(1, 10));
        }
      }
      // 出题在手机上同步做：50 道里最慢的专家档也要很快。
      expect(watch.elapsedMilliseconds, lessThan(5000));
    });

    test('按提示判定，不和参考解逐格比', () {
      // 两种涂法提示相同（对角两格）：这种题不会出，但判定只看提示。
      const puzzle = NonogramPuzzle(width: 2, height: 2, rows: [[1], [1]], columns: [[1], [1]]);
      expect(rules.solved(puzzle, [true, false, false, true]), isTrue);
      expect(rules.solved(puzzle, [false, true, true, false]), isTrue);
      expect(rules.solved(puzzle, [true, true, false, false]), isFalse);
    });

    test('编解码往返，坏输入抛 FormatException', () {
      final draw = rules.generate(9, PuzzleTier.normal);
      final puzzle = rules.decodePuzzle(rules.encodePuzzle(draw.puzzle));
      expect(puzzle.rows, draw.puzzle.rows);
      expect(rules.solved(puzzle, rules.decodeAnswer(rules.encodeAnswer(draw.solution))), isTrue);
      expect(() => rules.decodePuzzle({'width': 2, 'height': 1, 'rows': [[3]], 'columns': [[1], [1]]}), throwsFormatException);
      expect(() => rules.decodePuzzle({'width': 2, 'height': 1, 'rows': [[1]], 'columns': [[1]]}), throwsFormatException);
      expect(() => rules.decodeAnswer('012'), throwsFormatException);
    });
  });
}

// 测试另写的最少步数：局面用每根柱子的叠放（拼成字符串作键）广度优先，挪法的方向也另写一遍，与规则里按位编码的搜索互相核对。
int _hanoiBrute(HanoiPuzzle puzzle) {
  String key(List<List<int>> stacks) => stacks.map((stack) => stack.join(',')).join('|');
  final goal = key(hanoiStacks(puzzle.pegs, puzzle.goal));
  var frontier = [hanoiStacks(puzzle.pegs, puzzle.start)];
  final seen = {key(frontier.first)};
  for (var steps = 0; frontier.isNotEmpty; steps++) {
    final next = <List<List<int>>>[];
    for (final stacks in frontier) {
      if (key(stacks) == goal) return steps;
      for (var from = 0; from < puzzle.pegs; from++) {
        for (var to = 0; to < puzzle.pegs; to++) {
          final allowed = switch (puzzle.variant) {
            HanoiVariant.classic => from != to,
            HanoiVariant.adjacent => (from - to).abs() == 1,
            HanoiVariant.cyclic => to == (from + 1) % puzzle.pegs,
          };
          if (!allowed || stacks[from].isEmpty || (stacks[to].isNotEmpty && stacks[to].last < stacks[from].last)) continue;
          final moved = [for (final stack in stacks) [...stack]];
          moved[to].add(moved[from].removeLast());
          if (seen.add(key(moved))) next.add(moved);
        }
      }
    }
    frontier = next;
  }
  return -1;
}
