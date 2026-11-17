import 'dart:math' as math;

import 'package:superxd/playground/puzzle_rules.dart';

// 数织（Nonogram）：按每行每列的提示数字涂格，提示是这一行（列）里连续涂色段的长度、按顺序排列，段与段之间至少空一格。
// 出的题保证只靠逐行逐列推理就能唯一解出（逐行求解器解得开才出），不用猜。
class NonogramPuzzle {
  const NonogramPuzzle({required this.width, required this.height, required this.rows, required this.columns});
  final int width;
  final int height;
  final List<List<int>> rows;
  final List<List<int>> columns;
}

const nonogramMaxSide = 25;

// 一行（列）的涂色段：连续涂色格的长度，按顺序。全空是空列表。
List<int> nonogramRuns(Iterable<bool> line) {
  final runs = <int>[];
  var run = 0;
  for (final filled in line) {
    if (filled) {
      run++;
    } else if (run > 0) {
      runs.add(run);
      run = 0;
    }
  }
  if (run > 0) runs.add(run);
  return runs;
}

bool _sameRuns(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

NonogramPuzzle nonogramClues(List<bool> grid, int width, int height) => NonogramPuzzle(
  width: width,
  height: height,
  rows: [for (var row = 0; row < height; row++) nonogramRuns(grid.sublist(row * width, (row + 1) * width))],
  columns: [for (var column = 0; column < width; column++) nonogramRuns([for (var row = 0; row < height; row++) grid[row * width + column]])],
);

// 逐行求解里一格的状态。
enum NonogramCell { unknown, filled, empty }

// 一行的推理：在已知格的约束下列出所有可能的排法，所有排法里都涂的格定为涂、都空的格定为空。
// 动态规划：ahead[i][j] = 前 i 格能放下前 j 段，behind[i][j] = 从第 i 格起能放下第 j 段及以后；一段放在 [s, s+len) 且后面一格留空。
// 返回推理后的这一行；和已知格矛盾返回 null。
List<NonogramCell>? nonogramSolveLine(List<int> clue, List<NonogramCell> cells) {
  final length = cells.length, count = clue.length;
  bool canEmpty(int index) => cells[index] != NonogramCell.filled;
  // 已定为空的格数前缀和：[from, to) 里没有已定为空的格才能整段涂上。
  final emptyBefore = List.filled(length + 1, 0);
  for (var index = 0; index < length; index++) {
    emptyBefore[index + 1] = emptyBefore[index] + (cells[index] == NonogramCell.empty ? 1 : 0);
  }
  bool canFill(int from, int to) => to <= length && emptyBefore[to] - emptyBefore[from] == 0;
  // 一段结束在 end 时消耗掉后面那一格空格，落在 next(end)。
  int next(int end) => end < length ? end + 1 : end;
  bool gapOk(int end) => end >= length || canEmpty(end);

  final ahead = [for (var index = 0; index <= length; index++) List.filled(count + 1, false)];
  ahead[0][0] = true;
  for (var index = 0; index < length; index++) {
    for (var run = 0; run <= count; run++) {
      if (!ahead[index][run]) continue;
      if (canEmpty(index)) ahead[index + 1][run] = true;
      if (run < count) {
        final end = index + clue[run];
        if (canFill(index, end) && gapOk(end)) ahead[next(end)][run + 1] = true;
      }
    }
  }
  if (!ahead[length][count]) return null;

  final behind = [for (var index = 0; index <= length; index++) List.filled(count + 1, false)];
  behind[length][count] = true;
  for (var index = length - 1; index >= 0; index--) {
    for (var run = count; run >= 0; run--) {
      if (canEmpty(index) && behind[index + 1][run]) behind[index][run] = true;
      if (run < count) {
        final end = index + clue[run];
        if (canFill(index, end) && gapOk(end) && behind[next(end)][run + 1]) behind[index][run] = true;
      }
    }
  }

  final mayFill = List.filled(length + 1, 0), mayEmpty = List.filled(length, false);
  for (var index = 0; index < length; index++) {
    for (var run = 0; run <= count; run++) {
      if (!ahead[index][run]) continue;
      if (canEmpty(index) && behind[index + 1][run]) mayEmpty[index] = true;
      if (run < count) {
        final end = index + clue[run];
        if (canFill(index, end) && gapOk(end) && behind[next(end)][run + 1]) {
          mayFill[index]++;
          mayFill[end]--;
          if (end < length) mayEmpty[end] = true;
        }
      }
    }
  }
  final result = <NonogramCell>[];
  var covering = 0;
  for (var index = 0; index < length; index++) {
    covering += mayFill[index];
    final fill = covering > 0, empty = mayEmpty[index];
    result.add(fill && empty ? cells[index] : fill ? NonogramCell.filled : NonogramCell.empty);
  }
  return result;
}

// 逐行逐列反复推理直到不再变化。返回解开时用了几轮（一轮 = 所有行加所有列各推一遍），解不开（要猜或无解）返回 null。
int? nonogramLineSolve(NonogramPuzzle puzzle) {
  final width = puzzle.width, height = puzzle.height;
  final grid = List.filled(width * height, NonogramCell.unknown);
  for (var sweep = 1; sweep <= width * height; sweep++) {
    var changed = false;
    for (var row = 0; row < height; row++) {
      final line = nonogramSolveLine(puzzle.rows[row], grid.sublist(row * width, (row + 1) * width));
      if (line == null) return null;
      for (var column = 0; column < width; column++) {
        if (grid[row * width + column] != line[column]) {
          grid[row * width + column] = line[column];
          changed = true;
        }
      }
    }
    for (var column = 0; column < width; column++) {
      final line = nonogramSolveLine(puzzle.columns[column], [for (var row = 0; row < height; row++) grid[row * width + column]]);
      if (line == null) return null;
      for (var row = 0; row < height; row++) {
        if (grid[row * width + column] != line[row]) {
          grid[row * width + column] = line[row];
          changed = true;
        }
      }
    }
    if (!grid.contains(NonogramCell.unknown)) return sweep;
    if (!changed) return null;
  }
  return null;
}

class NonogramRules extends PuzzleRules<NonogramPuzzle, List<bool>> {
  const NonogramRules();

  // 挑战里的特性（[人工决策-2026-11-16 17:26:21] 见 puzzle_rules.dart 的 PuzzleRules.fragment）。
  // 碎片是涂了几格。不收碎片：只有一段的行挖掉提示后逐行推不下去的，40 道里只有一两道。
  @override
  int? fragment(NonogramPuzzle puzzle, List<bool> solution) => solution.where((cell) => cell).length;

  // 每档的边长、一行最多几段提示（多了提示栏太宽，手机上格子会挤得点不准）、逐行求解要的轮数区间（含两端）与要不要左右对称。
  // 轮数是这一档的推理深度：1 轮是每行推一遍、每列再推一遍就全定下，越多越要行列来回对照。区间按预计用时卡在各档的难度分里
  // （入门 3、简单 4、普通 5、困难 6、专家 7，五档不重叠，见 expectedSeconds），所以高档不只是变大、也要多推几轮。
  // 11-17 小修（每档 300 个种子实测）：原来 5、7、10、12、15 见方不限轮数，五档预计用时中位 35、55、138、217、540 秒、难度分 3、3–5、4–6、6–8、8–10 互相重叠，
  // 入门有四分之三一轮就推完；入门对称时 5 见方只有十几位能变，300 道里只有 219 种（不对称 2000 道里 1925 种）。现在约 47、61、109、175、302 秒。
  static const _tiers = {
    PuzzleTier.entry: (side: 5, runs: 3, sweeps: (2, 2), mirrored: false),
    PuzzleTier.easy: (side: 7, runs: 4, sweeps: (2, 3), mirrored: true),
    PuzzleTier.normal: (side: 10, runs: 5, sweeps: (2, 3), mirrored: true),
    PuzzleTier.hard: (side: 11, runs: 5, sweeps: (3, 4), mirrored: false),
    PuzzleTier.expert: (side: 13, runs: 6, sweeps: (3, 4), mirrored: false),
  };

  // 出图：随机涂一半多一点，再按九宫格多数平滑一遍成块（像小像素画而不是噪点），简单、普通左右对称更像图案；
  // 逐行求解器解得开、轮数落在这一档的区间才用，否则换下一张（平均三四张出一道，一张不到 1 毫秒）。
  @override
  PuzzleDraw<NonogramPuzzle, List<bool>> generate(int seed, PuzzleTier tier) {
    final (:side, runs: maxRuns, sweeps: (low, high), :mirrored) = _tiers[tier]!;
    final random = PuzzleRandom(seed);
    while (true) {
      var grid = [for (var index = 0; index < side * side; index++) random.chance(.58)];
      grid = _smooth(grid, side, random);
      if (mirrored) {
        for (var row = 0; row < side; row++) {
          for (var column = side ~/ 2; column < side; column++) {
            grid[row * side + column] = grid[row * side + side - 1 - column];
          }
        }
      }
      final filled = grid.where((cell) => cell).length;
      if (filled < side * side * .35 || filled > side * side * .75) continue;
      final puzzle = nonogramClues(grid, side, side);
      if ([...puzzle.rows, ...puzzle.columns].any((runs) => runs.length > maxRuns || runs.isEmpty)) continue;
      final sweeps = nonogramLineSolve(puzzle);
      if (sweeps == null || sweeps < low || sweeps > high) continue;
      return PuzzleDraw(puzzle, grid);
    }
  }

  static List<bool> _smooth(List<bool> grid, int side, PuzzleRandom random) => [
    for (var row = 0; row < side; row++)
      for (var column = 0; column < side; column++)
        () {
          var around = 0, total = 0;
          for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              final y = row + dy, x = column + dx;
              if (y < 0 || y >= side || x < 0 || x >= side) continue;
              total++;
              if (grid[y * side + x]) around++;
            }
          }
          // 正好一半时随机定，免得平滑后整块对称得过分规整。
          return around * 2 == total ? random.chance(.5) : around * 2 > total;
        }(),
  ];

  @override
  bool solved(NonogramPuzzle puzzle, List<bool> answer) {
    if (answer.length != puzzle.width * puzzle.height) return false;
    final check = nonogramClues(answer, puzzle.width, puzzle.height);
    for (var row = 0; row < puzzle.height; row++) {
      if (!_sameRuns(check.rows[row], puzzle.rows[row])) return false;
    }
    for (var column = 0; column < puzzle.width; column++) {
      if (!_sameRuns(check.columns[column], puzzle.columns[column])) return false;
    }
    return true;
  }

  // 难易按格数与推理轮数：分 = 格数 / 40 + 轮数 / 2（解不开按 10 轮），complexity 取整：入门 2、简单 2–3、普通 4、困难 5、专家 6。
  // 预计用时：5 见方一轮约 37 秒、15 见方三轮约 9 分半（按常见的人工解题速度估），按没取整的分每高 1 乘 1.578（同 puzzlePace 的口径；
  // 取整后再换算时同档的题只落在一两级上，五档的中位数离目标远）。
  @override
  int expectedSeconds(NonogramPuzzle puzzle) => (35 * math.pow(1.578, _score(puzzle) - 1)).round();

  @override
  int complexity(NonogramPuzzle puzzle) => _score(puzzle).round();

  static double _score(NonogramPuzzle puzzle) => (puzzle.width * puzzle.height / 40 + (nonogramLineSolve(puzzle) ?? 10) * .5).clamp(1, 10);

  @override
  Object encodePuzzle(NonogramPuzzle puzzle) => {'width': puzzle.width, 'height': puzzle.height, 'rows': puzzle.rows, 'columns': puzzle.columns};

  @override
  NonogramPuzzle decodePuzzle(Object? json) {
    final width = puzzleInt(json, 'width', min: 1, max: nonogramMaxSide), height = puzzleInt(json, 'height', min: 1, max: nonogramMaxSide);
    List<List<int>> lines(Object? value, int count, int length) {
      if (value is! List || value.length != count) throw const FormatException('提示行数不对');
      return [
        for (final line in value)
          () {
            final runs = puzzleInts(line, maxLength: (length + 1) ~/ 2, min: 1, max: length);
            if (runs.fold(0, (sum, run) => sum + run) + runs.length - 1 > length) throw const FormatException('提示超出这一行');
            return runs;
          }(),
      ];
    }

    final map = json as Map;
    return NonogramPuzzle(width: width, height: height, rows: lines(map['rows'], height, width), columns: lines(map['columns'], width, height));
  }

  // 答案按行优先编成 0 与 1 的字符串。
  @override
  Object encodeAnswer(List<bool> answer) => answer.map((filled) => filled ? '1' : '0').join();

  @override
  List<bool> decodeAnswer(Object? json) {
    if (json is! String || json.length > nonogramMaxSide * nonogramMaxSide || !RegExp(r'^[01]*$').hasMatch(json)) throw const FormatException('答案不合法');
    return [for (final char in json.split('')) char == '1'];
  }
}
