import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/puzzle/hanoi/hanoi_rules.dart';
import 'package:superxd/playground/puzzle/nonogram/nonogram_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';

void main() {
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

    test('最少步数：经典开局 2^n−1，打乱开局按最大盘的位置递推', () {
      expect(hanoiMinMoves([0, 0, 0], 2), 7);
      expect(hanoiMinMoves(List.filled(7, 0), 2), 127);
      // 最大的盘已在目标柱：只看剩下两个。
      expect(hanoiMinMoves([0, 0, 2], 2), 3);
      expect(hanoiMinMoves([2, 2, 2], 2), 0);
    });

    test('每档出的题都没解开，参考解是最少步数且判定为解开', () {
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 20; seed++) {
          final draw = rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          expect(rules.solved(puzzle, const []), isFalse, reason: '$tier $seed');
          expect(draw.solution.length, hanoiMinMoves(puzzle.start, puzzle.target));
          expect(rules.solved(puzzle, draw.solution), isTrue);
          expect(rules.difficulty(puzzle), inInclusiveRange(1, 10));
        }
      }
      expect(rules.generate(3, PuzzleTier.hard).puzzle.start, rules.generate(3, PuzzleTier.hard).puzzle.start);
    });

    test('大盘压小盘、从空柱挪、没挪完都不算解开', () {
      const puzzle = HanoiPuzzle(disks: 2, start: [0, 0], target: 2);
      expect(rules.solved(puzzle, [(from: 0, to: 1), (from: 0, to: 1)]), isFalse);
      // 只靠大盘压小盘才能两步全到目标柱：必须判为没解开。
      expect(rules.solved(puzzle, [(from: 0, to: 2), (from: 0, to: 2)]), isFalse);
      expect(rules.solved(puzzle, [(from: 1, to: 2)]), isFalse);
      expect(rules.solved(puzzle, [(from: 0, to: 1), (from: 0, to: 2)]), isFalse);
      expect(rules.solved(puzzle, [(from: 0, to: 1), (from: 0, to: 2), (from: 1, to: 2)]), isTrue);
    });

    test('编解码往返，坏输入抛 FormatException', () {
      final draw = rules.generate(5, PuzzleTier.expert);
      final puzzle = rules.decodePuzzle(rules.encodePuzzle(draw.puzzle));
      expect(puzzle.start, draw.puzzle.start);
      expect(rules.solved(puzzle, rules.decodeAnswer(rules.encodeAnswer(draw.solution))), isTrue);
      expect(() => rules.decodePuzzle({'disks': 3, 'start': [0, 0], 'target': 2}), throwsFormatException);
      expect(() => rules.decodePuzzle({'disks': 3, 'start': [0, 0, 3], 'target': 2}), throwsFormatException);
      expect(() => rules.decodeAnswer([9]), throwsFormatException);
      expect(() => rules.decodeAnswer('0'), throwsFormatException);
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
