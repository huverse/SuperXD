import 'package:superxd/playground/puzzle_rules.dart';

// 点灯（Lights Out）：每格一盏灯，点一格会翻转它自己和上下左右相邻的格（亮变灭、灭变亮），把全部灯点亮即解开。
// 同一格点两下等于没点、点的先后不影响结果，所以一道题的解就是「哪些格点奇数次」，按 GF(2) 上的线性方程组求。
class LightsPuzzle {
  const LightsPuzzle({required this.side, required this.lit});
  final int side;
  // 按行优先，true 是亮着。
  final List<bool> lit;
}

// 题面边长只收档位里有的 3 到 7：求解用位掩码，7×7 共 49 位再加一位方程右边，要 64 位整数（Dart 原生的 int；
// 题库工具与本机都是 Dart，服务器只核对答案、按步翻转即可，用不到求解器）。
const lightsMinSide = 3;
const lightsMaxSide = 7;
// 一局最多记这么多下（外部输入的上限；专家档最少二十来下，留足点错再撤回的余地）。
const lightsMaxPresses = 1024;

// 点第 cell 格会翻转的格：自己和上下左右（边上、角上的少一两格）。翻转关系是对称的：点 a 会翻 b，点 b 也会翻 a。
List<int> lightsReach(int side, int cell) {
  final row = cell ~/ side, column = cell % side;
  return [
    cell,
    if (row > 0) cell - side,
    if (row < side - 1) cell + side,
    if (column > 0) cell - 1,
    if (column < side - 1) cell + 1,
  ];
}

// 在 lit 上点一下第 cell 格（原地翻转）。
void lightsPress(List<bool> lit, int side, int cell) {
  for (final reached in lightsReach(side, cell)) {
    lit[reached] = !lit[reached];
  }
}

// 从题面依次点 presses 里的格，返回点完的灯；有一格不在棋盘上返回 null。
List<bool>? lightsReplay(LightsPuzzle puzzle, Iterable<int> presses) {
  final lit = [...puzzle.lit];
  final count = puzzle.side * puzzle.side;
  for (final cell in presses) {
    if (cell < 0 || cell >= count) return null;
    lightsPress(lit, puzzle.side, cell);
  }
  return lit;
}

int _bits(int value) {
  var count = 0;
  for (var rest = value; rest != 0; rest &= rest - 1) {
    count++;
  }
  return count;
}

// 最少点哪几格（升序）：在 GF(2) 上解 A·x = b。A 的第 j 行是「点哪些格会翻转第 j 格」，b 的第 j 位是第 j 格要不要翻奇数次（现在灭着就要）。
// 高斯消元化成最简行阶梯，自由变量取 0 得一个特解；零空间不为零时（3 到 7 里只有 4×4 是 4 维、5×5 是 2 维，其余满秩）
// 枚举零空间全部组合与特解相加，取点得最少的一组，同样少时取先枚举到的（结果只由题面决定，换实现也一样）。无解返回 null。
List<int>? lightsSolve(LightsPuzzle puzzle) {
  final side = puzzle.side, count = side * side;
  // 每个方程一个整数：低 count 位是系数，第 count 位是右边。
  final rows = [
    for (var cell = 0; cell < count; cell++)
      lightsReach(side, cell).fold(0, (mask, reached) => mask | 1 << reached) | (puzzle.lit[cell] ? 0 : 1 << count),
  ];
  final pivots = <int>[];
  for (var column = 0; column < count && pivots.length < count; column++) {
    final rank = pivots.length;
    var found = rank;
    while (found < count && rows[found] >> column & 1 == 0) {
      found++;
    }
    if (found == count) continue;
    final pivot = rows[found];
    rows[found] = rows[rank];
    rows[rank] = pivot;
    for (var other = 0; other < count; other++) {
      if (other != rank && rows[other] >> column & 1 == 1) rows[other] ^= pivot;
    }
    pivots.add(column);
  }
  // 系数全消成零的行，右边还是 1 就是矛盾：这个题面点不全亮。
  for (var row = pivots.length; row < count; row++) {
    if (rows[row] >> count & 1 == 1) return null;
  }
  var best = 0;
  for (final (row, column) in pivots.indexed) {
    if (rows[row] >> count & 1 == 1) best |= 1 << column;
  }
  // 零空间的基：每个自由变量置 1，各主元变量取它所在行里这一列的系数。
  final pivotColumns = pivots.toSet();
  final basis = [
    for (var free = 0; free < count; free++)
      if (!pivotColumns.contains(free))
        pivots.indexed.fold(1 << free, (vector, entry) => rows[entry.$1] >> free & 1 == 1 ? vector | 1 << entry.$2 : vector),
  ];
  final particular = best;
  var fewest = _bits(best);
  for (var combination = 1; combination < 1 << basis.length; combination++) {
    var candidate = particular;
    for (var index = 0; index < basis.length; index++) {
      if (combination >> index & 1 == 1) candidate ^= basis[index];
    }
    final presses = _bits(candidate);
    if (presses < fewest) {
      best = candidate;
      fewest = presses;
    }
  }
  return [for (var cell = 0; cell < count; cell++) if (best >> cell & 1 == 1) cell];
}

class LightsRules extends PuzzleRules<LightsPuzzle, List<int>> {
  const LightsRules();

  static const _sides = {PuzzleTier.entry: 3, PuzzleTier.easy: 4, PuzzleTier.normal: 5, PuzzleTier.hard: 6, PuzzleTier.expert: 7};
  // 每档「最少点几下」的区间：开局随机点的下数也从这里取。3×3、6×6、7×7 满秩，最少下数就是随机点的下数；
  // 4×4、5×5 有零空间，随机点的几下可能有更省的点法，最少下数会落到区间下面，这时换一组重来（实测 4×4 平均每 8 道重来一次、最多 3 次，5×5 更少）；
  // 4×4 的最少下数多落在 4、5（实测 2000 道里 7 下的不到百分之一），够「简单」用，不另调。
  // 区间上沿压着不放：7×7 随便点二三十下的局面对人来说和二十下差不多难，拉开只会让同档的分数散开。
  static const _least = {PuzzleTier.entry: (2, 4), PuzzleTier.easy: (4, 7), PuzzleTier.normal: (7, 11), PuzzleTier.hard: (10, 15), PuzzleTier.expert: (13, 20)};

  // 出题：从全亮开始，随机挑几格各点一下（不重复的格：同一格点两下等于没点），得到开局，所以一定解得开；
  // 再用求解器算最少下数，落在这一档的区间才用。下数至少 2，开局就不会已经全亮。
  @override
  PuzzleDraw<LightsPuzzle, List<int>> generate(int seed, PuzzleTier tier) {
    final side = _sides[tier]!;
    final (low, high) = _least[tier]!;
    final random = PuzzleRandom(seed);
    final cells = [for (var cell = 0; cell < side * side; cell++) cell];
    while (true) {
      final presses = low + random.nextInt(high - low + 1);
      random.shuffle(cells);
      final lit = List.filled(side * side, true);
      for (final cell in cells.take(presses)) {
        lightsPress(lit, side, cell);
      }
      final puzzle = LightsPuzzle(side: side, lit: lit);
      final solution = lightsSolve(puzzle)!;
      if (solution.length < low || solution.length > high) continue;
      return PuzzleDraw(puzzle, solution);
    }
  }

  @override
  bool solved(LightsPuzzle puzzle, List<int> answer) {
    if (answer.length > lightsMaxPresses) return false;
    final lit = lightsReplay(puzzle, answer);
    return lit != null && !lit.contains(false);
  }

  // 难度分：格数（要盯住的灯有多少）加最少下数（要找出的那几格有多少），格数 ÷ 10 + 最少下数 ÷ 6 + 0.3 再取整。
  // 按各档的格数与下数区间算：入门 2、简单 3、普通 4–5、困难 6、专家 7–9，同档相近、档与档之间不重叠地往上走
  // （与汉诺塔、数织的入门约 2 分、专家七八分同一把尺子，挑战模式按它计分）。解不开的题面不会出、也解码不进来，按 10 分算。
  @override
  int difficulty(LightsPuzzle puzzle) {
    final least = lightsSolve(puzzle)?.length;
    if (least == null) return 10;
    return (puzzle.side * puzzle.side / 10 + least / 6 + .3).round().clamp(1, 10);
  }

  // 题面编成边长与一串 0、1（按行优先，1 是亮）。
  @override
  Object encodePuzzle(LightsPuzzle puzzle) => {'side': puzzle.side, 'lights': puzzle.lit.map((on) => on ? '1' : '0').join()};

  @override
  LightsPuzzle decodePuzzle(Object? json) {
    final side = puzzleInt(json, 'side', min: lightsMinSide, max: lightsMaxSide);
    final lights = (json as Map)['lights'];
    if (lights is! String || lights.length != side * side || !RegExp(r'^[01]+$').hasMatch(lights)) throw const FormatException('灯的状态不合法');
    final puzzle = LightsPuzzle(side: side, lit: [for (final char in lights.split('')) char == '1']);
    // 已经全亮的不是题；4×4、5×5 有一半以上的局面怎么点都点不全亮，题库里不该有。
    if (!puzzle.lit.contains(false) || lightsSolve(puzzle) == null) throw const FormatException('题面已经全亮或解不开');
    return puzzle;
  }

  // 答案是依次点的格（行优先下标），最长 lightsMaxPresses 下。
  @override
  Object encodeAnswer(List<int> answer) => [...answer];

  @override
  List<int> decodeAnswer(Object? json) => puzzleInts(json, maxLength: lightsMaxPresses, min: 0, max: lightsMaxSide * lightsMaxSide - 1);
}
