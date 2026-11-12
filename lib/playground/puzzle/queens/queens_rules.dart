import 'package:superxd/playground/puzzle_rules.dart';

// 八皇后（N 皇后）：N×N 棋盘放 N 个皇后，任意两个不同行、不同列、不在同一条斜线上。
// 题面给出几个锁定的皇后，玩家补齐其余的；出的题保证补法唯一（求解器数到第 2 个解就停，唯一才出）。
class QueensPuzzle {
  const QueensPuzzle({required this.size, required this.given});
  final int size;
  // given[行] = 这一行锁定的皇后在第几列，没有锁定的是 -1。
  final List<int> given;
}

const queensMinSize = 4;
// 外部输入的上限：列可用位掩码放得进 32 位（换语言的核对器同样好写），专家档 12 留有余地。
const queensMaxSize = 16;

// 两个皇后是否互相攻击：同行、同列或同一条斜线。
bool queensAttack(int row, int column, int otherRow, int otherColumn) =>
    row == otherRow || column == otherColumn || (row - otherRow).abs() == (column - otherColumn).abs();

// 求解的结果：解的个数（数到 limit 就停）、第一个解（每行的列）与试探过的分支数。
typedef QueensSolveResult = ({int count, List<int>? first, int branches});

// 求解器：先放锁定的皇后，再反复做「某一行（或某一列）只剩一个能放的格就放上」的推理（同人解题时的逐行排除）；
// 推不动了，挑能放的格最少的那一行（或列）逐个试，分支数就是要靠试探的深度。行列选法固定，所以分支数与解在哪一列无关，
// 唯一解的题数满两个之前会把整棵树走完，分支数是这道题确定的值。
QueensSolveResult queensSolve(QueensPuzzle puzzle, {int limit = 2}) {
  final size = puzzle.size;
  final state = _QueensState(size);
  for (var row = 0; row < size; row++) {
    final column = puzzle.given[row];
    if (column >= 0 && !state.place(row, column)) return (count: 0, first: null, branches: 0);
  }
  var count = 0, branches = 0;
  List<int>? first;
  void search(_QueensState state) {
    if (!state.propagate()) return;
    if (state.complete) {
      count++;
      first ??= [...state.placed];
      return;
    }
    final (line, isRow) = state.narrowest();
    final cells = isRow ? state.columnsOf(line) : state.rowsOf(line);
    for (final cell in cells) {
      branches++;
      final child = state.copy();
      if (isRow) {
        child.place(line, cell);
      } else {
        child.place(cell, line);
      }
      search(child);
      if (count >= limit) return;
    }
  }

  search(state);
  return (count: count, first: first, branches: branches);
}

// 搜索状态：每行还能放的列（位掩码）与已放的列。
class _QueensState {
  _QueensState(this.size) : options = List.filled(size, (1 << size) - 1), placed = List.filled(size, -1);
  _QueensState._(this.size, this.options, this.placed);

  final int size;
  final List<int> options;
  final List<int> placed;

  _QueensState copy() => _QueensState._(size, [...options], [...placed]);

  bool get complete => !placed.contains(-1);

  // 放一个皇后，划掉其余空行里它攻击到的格；这一格本来就不能放返回 false。
  bool place(int row, int column) {
    if (options[row] & (1 << column) == 0) return false;
    placed[row] = column;
    options[row] = 1 << column;
    for (var other = 0; other < size; other++) {
      if (other == row || placed[other] >= 0) continue;
      final distance = (other - row).abs();
      var attacked = 1 << column;
      if (column + distance < size) attacked |= 1 << (column + distance);
      if (column - distance >= 0) attacked |= 1 << (column - distance);
      options[other] &= ~attacked;
    }
    return true;
  }

  int get _usedColumns => placed.fold(0, (used, column) => column >= 0 ? used | 1 << column : used);

  // 反复推理到不再变化：某行没有能放的格、某列没有能放的行即矛盾（N 个皇后必须每行每列各一个）。
  bool propagate() {
    var progressed = true;
    while (progressed) {
      progressed = false;
      for (var row = 0; row < size; row++) {
        if (placed[row] >= 0) continue;
        final mask = options[row];
        if (mask == 0) return false;
        if (mask & (mask - 1) == 0) {
          place(row, mask.bitLength - 1);
          progressed = true;
        }
      }
      var used = _usedColumns;
      for (var column = 0; column < size; column++) {
        if (used & (1 << column) != 0) continue;
        final rows = rowsOf(column);
        if (rows.isEmpty) return false;
        if (rows.length == 1) {
          place(rows.single, column);
          used |= 1 << column;
          progressed = true;
        }
      }
    }
    return true;
  }

  List<int> columnsOf(int row) => [for (var column = 0; column < size; column++) if (options[row] & (1 << column) != 0) column];

  List<int> rowsOf(int column) => [for (var row = 0; row < size; row++) if (placed[row] < 0 && options[row] & (1 << column) != 0) row];

  // 能放的格最少的那一行或那一列（一样少时取行、取靠前的）。
  (int, bool) narrowest() {
    var best = size + 1, line = -1, isRow = true;
    for (var row = 0; row < size; row++) {
      if (placed[row] >= 0) continue;
      final count = _bits(options[row]);
      if (count < best) (best, line, isRow) = (count, row, true);
    }
    final used = _usedColumns;
    for (var column = 0; column < size; column++) {
      if (used & (1 << column) != 0) continue;
      final count = rowsOf(column).length;
      if (count < best) (best, line, isRow) = (count, column, false);
    }
    return (line, isRow);
  }

  static int _bits(int mask) {
    var count = 0;
    for (var rest = mask; rest != 0; rest &= rest - 1) {
      count++;
    }
    return count;
  }
}

class QueensRules extends PuzzleRules<QueensPuzzle, List<int>> {
  const QueensRules();

  static const _sizes = {PuzzleTier.entry: 5, PuzzleTier.easy: 6, PuzzleTier.normal: 8, PuzzleTier.hard: 10, PuzzleTier.expert: 12};
  // 高档出几道候选、留提示最少（一样少时要试探最深）的那道：档越高提示越少、推理越深。一道 12×12 不到 1 毫秒，八道也不卡界面。
  static const _candidates = {PuzzleTier.entry: 1, PuzzleTier.easy: 1, PuzzleTier.normal: 4, PuzzleTier.hard: 6, PuzzleTier.expert: 8};

  @override
  PuzzleDraw<QueensPuzzle, List<int>> generate(int seed, PuzzleTier tier) {
    final size = _sizes[tier]!;
    final random = PuzzleRandom(seed);
    PuzzleDraw<QueensPuzzle, List<int>>? best;
    var bestHints = size + 1, bestBranches = -1;
    for (var candidate = 0; candidate < _candidates[tier]!; candidate++) {
      final draw = _draw(size, random);
      final hints = draw.puzzle.given.where((column) => column >= 0).length;
      final branches = queensSolve(draw.puzzle).branches;
      if (hints < bestHints || hints == bestHints && branches > bestBranches) (best, bestHints, bestBranches) = (draw, hints, branches);
    }
    return best!;
  }

  // 一道候选：随机顺序回溯取一个完整解；按随机顺序逐个把解里的皇后锁上，直到补法唯一；
  // 再按随机顺序试着拿掉多余的锁定皇后（拿掉后仍唯一就拿掉），剩下的每一个都少不了。
  static PuzzleDraw<QueensPuzzle, List<int>> _draw(int size, PuzzleRandom random) {
    final solution = _randomSolution(size, random);
    final given = List.filled(size, -1);
    bool unique() => queensSolve(QueensPuzzle(size: size, given: given)).count == 1;
    final order = [for (var row = 0; row < size; row++) row];
    random.shuffle(order);
    for (final row in order) {
      given[row] = solution[row];
      if (unique()) break;
    }
    final locked = [for (var row = 0; row < size; row++) if (given[row] >= 0) row];
    random.shuffle(locked);
    for (final row in locked) {
      given[row] = -1;
      if (!unique()) given[row] = solution[row];
    }
    return PuzzleDraw(QueensPuzzle(size: size, given: List.unmodifiable(given)), List.unmodifiable(solution));
  }

  // 随机顺序回溯：每一行把各列打乱了依次试，列与两条斜线各用一个位掩码记占用。
  static List<int> _randomSolution(int size, PuzzleRandom random) {
    final queens = List.filled(size, -1);
    bool fill(int row, int columns, int rising, int falling) {
      if (row == size) return true;
      final order = [for (var column = 0; column < size; column++) column];
      random.shuffle(order);
      for (final column in order) {
        final up = 1 << (row + column), down = 1 << (row - column + size - 1);
        if (columns & (1 << column) != 0 || rising & up != 0 || falling & down != 0) continue;
        queens[row] = column;
        if (fill(row + 1, columns | 1 << column, rising | up, falling | down)) return true;
      }
      return false;
    }

    fill(0, 0, 0, 0);
    return queens;
  }

  // 每行恰好一个、全部互不攻击、并且题面锁定的皇后都在原处。
  @override
  bool solved(QueensPuzzle puzzle, List<int> answer) {
    final size = puzzle.size;
    if (answer.length != size) return false;
    for (var row = 0; row < size; row++) {
      final column = answer[row];
      if (column < 0 || column >= size) return false;
      if (puzzle.given[row] >= 0 && puzzle.given[row] != column) return false;
      for (var other = 0; other < row; other++) {
        if (queensAttack(row, column, other, answer[other])) return false;
      }
    }
    return true;
  }

  // 难度分口径：以棋盘边长为主（要补的皇后与要排除的格都随边长涨），入门 5×5 记 1、专家 12×12 记 9，中间按边长线性取整
  // （6、8、10 记 2、4、7）；求解器要试探的分支多于边长（光靠逐行逐列排除推不完、得反复试）再加 1。
  // 所以同档的题最多差 1 分，下一档最低不低于上一档最高：5×5 是 1–2，6×6 是 2–3，8×8 是 4–5，10×10 是 7–8，12×12 是 9–10。
  @override
  int difficulty(QueensPuzzle puzzle) {
    final size = puzzle.size;
    final base = (1 + (size - 5) * 8 / 7).round();
    return (base + (queensSolve(puzzle).branches > size ? 1 : 0)).clamp(1, 10);
  }

  @override
  Object encodePuzzle(QueensPuzzle puzzle) => {'size': puzzle.size, 'given': puzzle.given};

  @override
  QueensPuzzle decodePuzzle(Object? json) {
    final size = puzzleInt(json, 'size', min: queensMinSize, max: queensMaxSize);
    final given = puzzleInts((json as Map)['given'], maxLength: queensMaxSize, min: -1, max: size - 1);
    if (given.length != size) throw const FormatException('锁定皇后的行数不对');
    // 锁定的皇后互相攻击的题永远解不开，当坏题拒收。
    for (var row = 0; row < size; row++) {
      for (var other = 0; other < row; other++) {
        if (given[row] >= 0 && given[other] >= 0 && queensAttack(row, given[row], other, given[other])) throw const FormatException('锁定的皇后互相攻击');
      }
    }
    return QueensPuzzle(size: size, given: List.unmodifiable(given));
  }

  // 答案是长度 N 的列表：每行皇后所在的列，没放是 -1。
  @override
  Object encodeAnswer(List<int> answer) => answer;

  @override
  List<int> decodeAnswer(Object? json) => puzzleInts(json, maxLength: queensMaxSize, min: -1, max: queensMaxSize - 1);
}
