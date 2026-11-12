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

  static const _sides = {PuzzleTier.entry: 5, PuzzleTier.easy: 7, PuzzleTier.normal: 10, PuzzleTier.hard: 12, PuzzleTier.expert: 15};
  // 一行最多几段提示：多了提示栏太宽，手机上格子会挤得点不准。
  static const _maxRuns = {5: 3, 7: 4, 10: 5, 12: 5, 15: 6};

  // 出图：随机涂一半多一点，再按九宫格多数平滑一遍成块（像小像素画而不是噪点），小档左右对称更像图案；逐行求解器解得开才用，否则换下一张。
  @override
  PuzzleDraw<NonogramPuzzle, List<bool>> generate(int seed, PuzzleTier tier) {
    final side = _sides[tier]!, maxRuns = _maxRuns[side]!;
    final random = PuzzleRandom(seed);
    final mirrored = tier.index <= PuzzleTier.normal.index;
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
      if (nonogramLineSolve(puzzle) == null) continue;
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

  // 格数与推理轮数：5×5 约 2 分，15×15 约 7–9 分。
  @override
  int difficulty(NonogramPuzzle puzzle) {
    final sweeps = nonogramLineSolve(puzzle) ?? 10;
    return (puzzle.width * puzzle.height / 40 + sweeps * .5).round().clamp(1, 10);
  }

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
