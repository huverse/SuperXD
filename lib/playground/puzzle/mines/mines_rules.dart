import 'dart:math' as math;

import 'package:superxd/playground/puzzle_rules.dart';

// 扫雷（无猜）：格子里藏着雷，翻开的格写着周围八格里有几颗雷；把所有不是雷的格翻完就解开。
// 开局起点那一片已经翻开；出的题保证从起点开始只靠推理就能翻完（求解器推得完才出），不用猜。
class MinesPuzzle {
  const MinesPuzzle({required this.width, required this.height, required this.mines, required this.start});
  final int width;
  final int height;
  // mines[行 × width + 列]：这一格是不是雷。
  final List<bool> mines;
  // 开局已经翻开的那一格（周围没有雷，翻开时连开一片）。
  final int start;
}

const minesMinSide = 5;
const minesMaxSide = 24;

// 一格周围的八格（只算棋盘里的）。
List<int> minesAround(int width, int height, int cell) {
  final row = cell ~/ width, column = cell % width;
  return [
    for (var dy = -1; dy <= 1; dy++)
      for (var dx = -1; dx <= 1; dx++)
        if ((dy != 0 || dx != 0) && row + dy >= 0 && row + dy < height && column + dx >= 0 && column + dx < width) (row + dy) * width + column + dx,
  ];
}

// 每格周围有几颗雷。
List<int> minesCounts(MinesPuzzle puzzle) => [
  for (var cell = 0; cell < puzzle.mines.length; cell++) minesAround(puzzle.width, puzzle.height, cell).where((other) => puzzle.mines[other]).length,
];

// 翻开一格（调用方保证不是雷）：是 0 就连开周围一片（同经典扫雷）。open 原地改；
// 返回这次新翻开的格与离点的那一格隔了几圈（从 ring 起算），按圈排好，对局页按圈淡出。
List<(int, int)> minesOpen(MinesPuzzle puzzle, List<int> counts, List<bool> open, int cell, {int ring = 0}) {
  if (open[cell]) return const [];
  open[cell] = true;
  final opened = [(cell, ring)];
  for (var index = 0; index < opened.length; index++) {
    final (current, distance) = opened[index];
    if (counts[current] != 0) continue;
    for (final other in minesAround(puzzle.width, puzzle.height, current)) {
      if (open[other]) continue;
      open[other] = true;
      opened.add((other, distance + 1));
    }
  }
  return opened;
}

// 开局的局面：起点那一片翻开。
List<bool> minesStartOpen(MinesPuzzle puzzle, List<int> counts) {
  final open = List.filled(puzzle.mines.length, false);
  minesOpen(puzzle, counts, open, puzzle.start);
  return open;
}

// 点一格翻开（答案里的一步）：没翻开的格直接翻；已翻开的数字格是「点数字连开」，把周围没翻开的格一起翻开
// （对局页要求周围插旗数等于数字才连开，插对了翻开的正好是周围不是雷的格；旗子不进答案，这里按插对了重放）。
// 返回新翻开的格；越界、翻到雷、点了翻不开任何格的格（重复翻已翻的、0 格、周围只剩雷的数字）返回 null。
List<(int, int)>? minesStep(MinesPuzzle puzzle, List<int> counts, List<bool> open, int cell) {
  if (cell < 0 || cell >= puzzle.mines.length) return null;
  if (!open[cell]) return puzzle.mines[cell] ? null : minesOpen(puzzle, counts, open, cell);
  final opened = <(int, int)>[];
  for (final other in minesAround(puzzle.width, puzzle.height, cell)) {
    if (!open[other] && !puzzle.mines[other]) opened.addAll(minesOpen(puzzle, counts, open, other, ring: 1));
  }
  return opened.isEmpty ? null : opened;
}

// 按序重放翻开的动作，返回最后的局面；有一步不合法返回 null。
List<bool>? minesReplay(MinesPuzzle puzzle, List<int> moves) {
  final counts = minesCounts(puzzle);
  final open = minesStartOpen(puzzle, counts);
  for (final cell in moves) {
    if (minesStep(puzzle, counts, open, cell) == null) return null;
  }
  return open;
}

// 推理用到的规则层级：单格（一个数字自己就定得下）、子集（两个数字比一比）、全局（加上剩余雷数）。
enum MinesRule { single, subset, global }

// 求解的结果：推没推完、各层规则各用了几轮（一轮 = 低层推不动了、这一层推出至少一格），与按推理顺序点的格（参考解）。
typedef MinesSolveResult = ({bool solved, int singles, int subsets, int globals, List<int> taps});

// 求解器：从起点那一片开始，模拟人一步步推理（推出安全就翻开、推出是雷就记下），只有低层推不动了才用高一层：
// 1. 单格：数字减去周围已知的雷 = 0，其余未翻格都安全；= 未翻格数，未翻格全是雷。
// 2. 子集（两格对比）：数字 A、B 各自剩 rA、rB 颗雷没找到，A 独有的未翻格有 k 个；rA − rB = k 时 A 独有的全是雷、B 独有的全安全
//    （B ⊇ A 且 rA = rB 时 B 多出来的安全，是它的特例）。只比相距两格以内的数字（再远没有共同的格）。
// 3. 全局：剩余雷数为 0 或等于未翻格数；或挑几组互不重叠的数字，它们要的雷加起来正好等于剩余雷数，其余未翻格都安全
//    （加上其余未翻格数正好等于剩余雷数时，其余全是雷）。
// 规则只用题面给得出的信息（数字与总雷数），推出的都对，所以推完就说明不用猜。maxRule 限制最高用到哪一层（测试与出题用）。
MinesSolveResult minesSolve(MinesPuzzle puzzle, {MinesRule maxRule = MinesRule.global}) {
  final width = puzzle.width, height = puzzle.height, cells = width * height;
  final around = [for (var cell = 0; cell < cells; cell++) minesAround(width, height, cell)];
  final counts = [for (var cell = 0; cell < cells; cell++) around[cell].where((other) => puzzle.mines[other]).length];
  final total = puzzle.mines.where((mine) => mine).length;
  // 每格的状态：0 未知、1 已翻开、2 推出是雷。
  final state = List.filled(cells, 0);
  var safeLeft = cells - total, minesFound = 0;
  final taps = <int>[];

  void open(int cell) {
    if (state[cell] != 0) return;
    final queue = [cell];
    state[cell] = 1;
    for (var index = 0; index < queue.length; index++) {
      final current = queue[index];
      safeLeft--;
      if (counts[current] != 0) continue;
      for (final other in around[current]) {
        if (state[other] != 0) continue;
        state[other] = 1;
        queue.add(other);
      }
    }
  }

  // 把推出来的安全格翻开（记进参考解）、雷记下；有新结论返回 true。
  bool apply(Set<int> safe, Set<int> mines) {
    for (final cell in mines) {
      if (state[cell] != 0) continue;
      state[cell] = 2;
      minesFound++;
    }
    var changed = mines.isNotEmpty;
    for (final cell in safe) {
      if (state[cell] != 0) continue;
      taps.add(cell);
      open(cell);
      changed = true;
    }
    return changed;
  }

  // 当前所有「还有未翻邻格的数字」：所在格、未翻邻格、还差几颗雷。
  List<(int, List<int>, int)> constraints() => [
    for (var cell = 0; cell < cells; cell++)
      if (state[cell] == 1 && counts[cell] > 0)
        if ([for (final other in around[cell]) if (state[other] == 0) other] case final unknown when unknown.isNotEmpty)
          (cell, unknown, counts[cell] - around[cell].where((other) => state[other] == 2).length),
  ];

  bool single() {
    final safe = <int>{}, mines = <int>{};
    for (final (_, unknown, left) in constraints()) {
      if (left == 0) safe.addAll(unknown);
      if (left == unknown.length) mines.addAll(unknown);
    }
    return apply(safe, mines);
  }

  bool subset() {
    final list = constraints();
    final index = List.filled(cells, -1);
    for (final (position, (cell, _, _)) in list.indexed) {
      index[cell] = position;
    }
    final safe = <int>{}, mines = <int>{};
    for (final (cell, unknown, left) in list) {
      final row = cell ~/ width, column = cell % width;
      for (var y = row - 2; y <= row + 2; y++) {
        for (var x = column - 2; x <= column + 2; x++) {
          if (y < 0 || y >= height || x < 0 || x >= width || (y == row && x == column)) continue;
          final other = index[y * width + x];
          if (other < 0) continue;
          final (_, otherUnknown, otherLeft) = list[other];
          final only = [for (final item in unknown) if (!otherUnknown.contains(item)) item];
          final otherOnly = [for (final item in otherUnknown) if (!unknown.contains(item)) item];
          if (only.isEmpty && otherOnly.isEmpty) continue;
          if (left - otherLeft == only.length) {
            mines.addAll(only);
            safe.addAll(otherOnly);
          }
        }
      }
    }
    return apply(safe, mines);
  }

  bool global() {
    final unknown = [for (var cell = 0; cell < cells; cell++) if (state[cell] == 0) cell];
    final remaining = total - minesFound;
    if (remaining == 0) return apply(unknown.toSet(), const {});
    if (remaining == unknown.length) return apply(const {}, unknown.toSet());
    // 互不重叠的一组数字：按还差的雷数从多到少、未翻邻格从少到多贪心挑。
    final list = constraints()..sort((a, b) => a.$3 != b.$3 ? b.$3 - a.$3 : a.$2.length - b.$2.length);
    final used = List.filled(cells, false);
    var packed = 0;
    for (final (_, group, left) in list) {
      if (group.any((cell) => used[cell])) continue;
      for (final cell in group) {
        used[cell] = true;
      }
      packed += left;
    }
    final rest = [for (final cell in unknown) if (!used[cell]) cell];
    if (rest.isEmpty) return false;
    if (packed == remaining) return apply(rest.toSet(), const {});
    if (packed + rest.length == remaining) return apply(const {}, rest.toSet());
    return false;
  }

  open(puzzle.start);
  var singles = 0, subsets = 0, globals = 0;
  while (safeLeft > 0) {
    if (single()) {
      singles++;
    } else if (maxRule.index >= MinesRule.subset.index && subset()) {
      subsets++;
    } else if (maxRule == MinesRule.global && global()) {
      globals++;
    } else {
      break;
    }
  }
  return (solved: safeLeft == 0, singles: singles, subsets: subsets, globals: globals, taps: taps);
}

class MinesRules extends PuzzleRules<MinesPuzzle, List<int>> {
  const MinesRules();

  // 挑战里的特性（[人工决策-2026-11-16 17:26:21] 见 puzzle_rules.dart 的 PuzzleRules.fragment）。
  // 碎片是第一行有几颗雷。
  @override
  int? fragment(MinesPuzzle puzzle, List<int> solution) => puzzle.mines.take(puzzle.width).where((mine) => mine).length;

  // 每档的边长、雷数（密度 14% 到 20% 逐档加）、至少要几轮子集或全局推理（minesDeep；普通起排除只靠单格就推得完的题，档越高要的越多），
  // 与预计用时的区间（秒，含两端）：落在难度分 3、4、5、6、7 各自的区间里，五档不重叠。
  // 11-17 小修（每档 300 道实测）：原来难易按雷数分段，同档的题不管开局翻开多少都算一样久，入门有一成翻开局面后点一两下就完；
  // 五档预计用时中位 46、61、111、199、360 秒，难度分 2–3、4、4、6–7、7–8。现在按每道题要翻几格算用时，区间外的重撒：
  // 中位约 44、69、107、180、267 秒；专家档平均撒二十来次，一次求解不到 1 毫秒。
  static const _tiers = {
    PuzzleTier.entry: (side: 6, mines: 5, deep: 0, seconds: (36, 56)),
    PuzzleTier.easy: (side: 8, mines: 10, deep: 0, seconds: (57, 92)),
    PuzzleTier.normal: (side: 9, mines: 15, deep: 1, seconds: (93, 152)),
    PuzzleTier.hard: (side: 12, mines: 28, deep: 2, seconds: (153, 249)),
    PuzzleTier.expert: (side: 14, mines: 40, deep: 3, seconds: (250, 409)),
  };

  // 出题：起点随机取一格不靠边的，起点和周围八格不放雷，其余格里随机撒雷；求解器从起点推得完、推理够深、预计用时落在这一档的区间才用，否则重撒。
  @override
  PuzzleDraw<MinesPuzzle, List<int>> generate(int seed, PuzzleTier tier) {
    final (:side, :mines, :deep, seconds: (least, most)) = _tiers[tier]!;
    final random = PuzzleRandom(seed);
    while (true) {
      final start = (1 + random.nextInt(side - 2)) * side + 1 + random.nextInt(side - 2);
      final keep = {start, ...minesAround(side, side, start)};
      final spots = [for (var cell = 0; cell < side * side; cell++) if (!keep.contains(cell)) cell];
      random.shuffle(spots);
      final layout = List.filled(side * side, false);
      for (final spot in spots.take(mines)) {
        layout[spot] = true;
      }
      final puzzle = MinesPuzzle(width: side, height: side, mines: List.unmodifiable(layout), start: start);
      final result = minesSolve(puzzle);
      if (!result.solved || result.taps.isEmpty || minesDeep(result) < deep) continue;
      final paced = minesSeconds(result);
      if (paced < least || paced > most) continue;
      return PuzzleDraw(puzzle, List.unmodifiable(result.taps));
    }
  }

  // 按序重放每一步都合法、没翻到雷，最后所有不是雷的格都翻开了。
  @override
  bool solved(MinesPuzzle puzzle, List<int> answer) {
    if (answer.length > puzzle.mines.length) return false;
    final open = minesReplay(puzzle, answer);
    if (open == null) return false;
    for (var cell = 0; cell < open.length; cell++) {
      if (!open[cell] && !puzzle.mines[cell]) return false;
    }
    return true;
  }

  @override
  int expectedSeconds(MinesPuzzle puzzle) => minesSeconds(minesSolve(puzzle));

  // 难易分直接由预计用时定（用时已按要翻几格与难推理的轮数算好，同汉诺塔）：难度分的每一档再对半分成两级，
  // 各档的用时区间对齐难度分 3–7，所以入门 1–2、简单 3–4、普通 5–6、困难 7–8、专家 9–10，五档分段不重叠。
  @override
  int complexity(MinesPuzzle puzzle) => ((1.4 * math.log(expectedSeconds(puzzle) / 10) / math.ln2 - 2.5) * 2).floor().clamp(0, 9) + 1;

  @override
  Object encodePuzzle(MinesPuzzle puzzle) => {
    'width': puzzle.width,
    'height': puzzle.height,
    'mines': puzzle.mines.map((mine) => mine ? '1' : '0').join(),
    'start': puzzle.start,
  };

  // 解码校验宽高、雷串与起点，并拒收推不完（要猜）或开局就全翻开的题。
  @override
  MinesPuzzle decodePuzzle(Object? json) {
    final width = puzzleInt(json, 'width', min: minesMinSide, max: minesMaxSide), height = puzzleInt(json, 'height', min: minesMinSide, max: minesMaxSide);
    final cells = width * height;
    final text = (json as Map)['mines'];
    if (text is! String || text.length != cells || !RegExp(r'^[01]*$').hasMatch(text)) throw const FormatException('雷的位置不合法');
    final mines = [for (final char in text.split('')) char == '1'];
    final start = puzzleInt(json, 'start', min: 0, max: cells - 1);
    if (mines[start]) throw const FormatException('起点是雷');
    final puzzle = MinesPuzzle(width: width, height: height, mines: List.unmodifiable(mines), start: start);
    final result = minesSolve(puzzle);
    if (!result.solved) throw const FormatException('这道题要靠猜');
    if (result.taps.isEmpty) throw const FormatException('开局就全翻开了');
    return puzzle;
  }

  // 每步一个格子下标（点了哪一格，点数字连开的也记那个数字格），插旗不进答案。
  @override
  Object encodeAnswer(List<int> answer) => [...answer];

  @override
  List<int> decodeAnswer(Object? json) => puzzleInts(json, maxLength: minesMaxSide * minesMaxSide, min: 0, max: minesMaxSide * minesMaxSide - 1);
}

// 推理量：子集推理的轮数加全局推理轮数的两倍（数雷要通盘看，比两格对比更难想到）。
int minesDeep(MinesSolveResult result) => result.subsets + result.globals * 2;

// 预计用时（秒）：看题 16 秒，开局之后每翻一格约 2.4 秒（看数字、想、点一下；参考解里一格一下，0 格连开的不算），
// 每轮子集或全局推理（minesDeep）另加 6 秒（要停下来比几个数字）。按常见的人工解题速度估：6 见方点十来下约 40 秒，14 见方点八十来下约 4 分半。
int minesSeconds(MinesSolveResult result) => (16 + 2.4 * result.taps.length + 6 * minesDeep(result)).round();
