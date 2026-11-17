import 'dart:math' as math;
import 'dart:typed_data';

import 'package:superxd/playground/puzzle_rules.dart';

// 点灯（Lights Out，题面写法第 2 版）：每格一盏灯，点一格会让它和相邻的几格各往亮走一级，把灯全部点亮即解开。
// 点的先后不影响结果，同一格点「状态数」下等于没点，所以一道题的解就是「每格点几下」，按 GF(2)（两态）或 GF(3)（三态）上的线性方程组求。
// 变体照经典的几种随档递进（参数写在 _kinds）：
// - 斜十字（Lights Out X）：点一格翻的是自己和四个斜角，不是上下左右；不是环面时棋盘按黑白格拆成互不相干的两半，要重新想影响范围。
// - 三态（Lights Out 2000）：灯分灭、暗、亮三级，点一下往亮走一级、亮了再点回到灭；有的格要点两下，两态「每格最多点一下」的想法解不开。
// - 环面（Toroidal Lights Out）：上下边、左右边相连，点边上的格也会影响对边；从上往下逐行追灯的套路走不通，要整体想。
// 每道题出之前核对用到的每条变体真起作用（lightsMatters）：拿掉斜十字或环面，同一个局面的最少下数会变或解不开；三态的题没有每格最多点一下的解。
class LightsPuzzle {
  const LightsPuzzle({required this.side, required this.cells, this.shape = LightsShape.plus, this.wrap = false, this.states = 2});
  final int side;
  final LightsShape shape;
  // 环面：上下边、左右边相连。
  final bool wrap;
  // 每盏灯几级：2 是灭、亮；3 是灭、暗、亮。
  final int states;
  // 每格的状态（行优先）：0 灭，states - 1 亮，三态时 1 是暗。
  final List<int> cells;

  // 亮着的那一级。
  int get lit => states - 1;
  bool get allLit => cells.every((state) => state == lit);

  LightsPuzzle copyWith({LightsShape? shape, bool? wrap, List<int>? cells}) =>
      LightsPuzzle(side: side, cells: cells ?? this.cells, shape: shape ?? this.shape, wrap: wrap ?? this.wrap, states: states);
}

// 点一格影响哪几格，code 发出后不改（题面里存它）。
enum LightsShape {
  // 十字：自己和上下左右。
  plus(0),
  // 斜十字：自己和四个斜角。
  diagonal(1);

  const LightsShape(this.code);
  final int code;
}

// 题面边长只收 3 到 7（7×7 在 360dp 上一格约 45dp，再大就点不准了）；灯的级数只收 2、3。
const lightsMinSide = 3;
const lightsMaxSide = 7;
const lightsMaxStates = 3;
// 一局最多记这么多下（外部输入的上限；专家档最少二十来下，留足点错再撤回的余地）。
const lightsMaxPresses = 1024;

// 点第 cell 格会影响的格（含自己）：十字是上下左右，斜十字是四个斜角；不是环面时出了棋盘的不算，环面时绕到对边。
// 影响关系是对称的：点 a 会影响 b，点 b 也会影响 a。边长至少 3，环面上绕过去的格也不会和别的重。
List<int> lightsReach(LightsPuzzle puzzle, int cell) {
  final side = puzzle.side, row = cell ~/ side, column = cell % side;
  final offsets = puzzle.shape == LightsShape.plus ? const [(-1, 0), (1, 0), (0, -1), (0, 1)] : const [(-1, -1), (-1, 1), (1, -1), (1, 1)];
  return [
    cell,
    for (final (down, right) in offsets)
      if (puzzle.wrap) (row + down) % side * side + (column + right) % side
      else if (row + down >= 0 && row + down < side && column + right >= 0 && column + right < side) (row + down) * side + column + right,
  ];
}

// 在 cells 上点一下第 cell 格（原地改）：影响到的每格往亮走一级，亮的回到灭。
void lightsPress(LightsPuzzle puzzle, List<int> cells, int cell) {
  for (final reached in lightsReach(puzzle, cell)) {
    cells[reached] = (cells[reached] + 1) % puzzle.states;
  }
}

// 从题面依次点 presses 里的格，返回点完的灯；有一格不在棋盘上返回 null。
List<int>? lightsReplay(LightsPuzzle puzzle, Iterable<int> presses) {
  final cells = [...puzzle.cells];
  final count = puzzle.side * puzzle.side;
  for (final cell in presses) {
    if (cell < 0 || cell >= count) return null;
    lightsPress(puzzle, cells, cell);
  }
  return cells;
}

// 「每格点几下」的全部解：particular 是一个解，basis 是零空间的基（每格点的下数按它们任意倍数相加，局面不变），都按 states 取模。
class LightsSolutions {
  const LightsSolutions._(this.states, this.particular, this.basis);
  final int states;
  final List<int> particular;
  final List<List<int>> basis;

  // 依次给出全部解（states 的「基的个数」次方个）：按基的系数从低位到高位数，先给自由变量全取 0 的那个。
  // 每次给的是同一个列表改过的，要留着就复制一份。
  Iterable<List<int>> get all sync* {
    final coefficients = List.filled(basis.length, 0);
    final current = [...particular];
    while (true) {
      yield current;
      // 系数像数位一样加一：这一位加一就把这个基加上一次，进位回到 0 时等于加了 states 次（不变），接着加下一位。
      var index = 0;
      while (index < basis.length) {
        final vector = basis[index];
        for (var cell = 0; cell < current.length; cell++) {
          current[cell] = (current[cell] + vector[cell]) % states;
        }
        coefficients[index] = (coefficients[index] + 1) % states;
        if (coefficients[index] != 0) break;
        index++;
      }
      if (index == basis.length) return;
    }
  }
}

// 在 GF(states) 上解 A·x = b：A 的第 i 行是「点哪些格会影响第 i 格」，b 的第 i 项是第 i 格还差几级到亮。
// 高斯消元化成最简行阶梯，自由变量取 0 得一个特解，每个自由变量各给零空间一个基；无解（这个局面点不全亮）返回 null。
LightsSolutions? lightsSolutions(LightsPuzzle puzzle) {
  final count = puzzle.side * puzzle.side, states = puzzle.states;
  // 每个方程一行：前 count 项是系数，最后一项是右边。
  final rows = [for (var cell = 0; cell < count; cell++) Int8List(count + 1)];
  for (var pressed = 0; pressed < count; pressed++) {
    for (final reached in lightsReach(puzzle, pressed)) {
      rows[reached][pressed] = 1;
    }
  }
  for (var cell = 0; cell < count; cell++) {
    rows[cell][count] = (puzzle.lit - puzzle.cells[cell]) % states;
  }
  final pivots = <int>[];
  for (var column = 0; column < count && pivots.length < count; column++) {
    final rank = pivots.length;
    var found = rank;
    while (found < count && rows[found][column] == 0) {
      found++;
    }
    if (found == count) continue;
    final pivot = rows[found];
    rows[found] = rows[rank];
    rows[rank] = pivot;
    // 主元化成 1：模 2 只有 1，模 3 的 2 乘 2 得 1。
    if (pivot[column] != 1) {
      for (var index = column; index <= count; index++) {
        pivot[index] = pivot[index] * 2 % 3;
      }
    }
    for (var other = 0; other < count; other++) {
      final factor = rows[other][column];
      if (other == rank || factor == 0) continue;
      final row = rows[other];
      for (var index = column; index <= count; index++) {
        row[index] = (row[index] - factor * pivot[index]) % states;
      }
    }
    pivots.add(column);
  }
  // 系数全消成零的行，右边不是 0 就是矛盾。
  for (var row = pivots.length; row < count; row++) {
    if (rows[row][count] != 0) return null;
  }
  final particular = List.filled(count, 0);
  for (final (row, column) in pivots.indexed) {
    particular[column] = rows[row][count];
  }
  // 每个主元变量在第几行。
  final pivotRow = {for (final (row, column) in pivots.indexed) column: row};
  final basis = [
    for (var free = 0; free < count; free++)
      if (!pivotRow.containsKey(free))
        [
          for (var cell = 0; cell < count; cell++)
            if (cell == free) 1 else if (pivotRow[cell] case final row?) (-rows[row][free]) % states else 0,
        ],
  ];
  return LightsSolutions._(states, particular, basis);
}

int _sum(List<int> presses) => presses.fold(0, (total, count) => total + count);

// 最少点哪几下（升序，三态时要点两下的格写两次）：在全部解里取下数最少的，同样少时取先数到的（结果只由题面决定）。点不全亮返回 null。
List<int>? lightsSolve(LightsPuzzle puzzle) {
  final solutions = lightsSolutions(puzzle);
  if (solutions == null) return null;
  List<int>? best;
  var fewest = 0;
  for (final presses in solutions.all) {
    final total = _sum(presses);
    if (best == null || total < fewest) {
      best = [...presses];
      fewest = total;
    }
  }
  return [
    for (var cell = 0; cell < best!.length; cell++)
      for (var time = 0; time < best[cell]; time++) cell,
  ];
}

// 用到的每条变体真起作用：拿掉斜十字（改回十字）或拿掉环面，同一个局面最少下数会变或解不开；三态的题每个解都有要点两下的格
// （「每格最多点一下」解不开）。lightsSolve 的结果 least 由调用方给，免得再解一遍。
bool lightsMatters(LightsPuzzle puzzle, int least) {
  bool differs(LightsPuzzle looser) => lightsSolve(looser)?.length != least;
  if (puzzle.shape == LightsShape.diagonal && !differs(puzzle.copyWith(shape: LightsShape.plus))) return false;
  if (puzzle.wrap && !differs(puzzle.copyWith(wrap: false))) return false;
  if (puzzle.states == 3 && lightsSolutions(puzzle)!.all.any((presses) => presses.every((count) => count <= 1))) return false;
  return true;
}

class LightsRules extends PuzzleRules<LightsPuzzle, List<int>> {
  const LightsRules();

  // 第 2 版：题面加形状、环面与级数，灯的状态从 0、1 改成 0 到级数减 1（两态的写法同第 1 版的 0、1）。
  @override
  int get puzzleVersion => 2;

  // 挑战里的特性（[人工决策-2026-11-16 17:26:21] 见 puzzle_rules.dart 的 PuzzleRules.fragment）。
  @override
  int? fragment(LightsPuzzle puzzle, List<int> solution) => lightsSolve(puzzle)!.length;
  @override
  int? minimum(LightsPuzzle puzzle) => lightsSolve(puzzle)!.length;

  // 每档的几种题（出题时按种子挑一种）：边长、形状、环面、级数。入门只有十字两态；简单加斜十字与三态（小棋盘）；普通加环面；
  // 困难、专家是大棋盘上的变体与两两组合。困难、专家在挑战里要正好最少下数，所以只用满秩的（解唯一：不多点一下就是最少），
  // 有零空间的（4×4、5×5 十字等）只放在低三档；3×3 环面（零空间 4 维、两三下就解开）与零空间大的（5×5、6×6 环面）都不用。
  static const _kinds = <PuzzleTier, List<({int side, LightsShape shape, bool wrap, int states})>>{
    PuzzleTier.entry: [(side: 3, shape: LightsShape.plus, wrap: false, states: 2), (side: 4, shape: LightsShape.plus, wrap: false, states: 2)],
    PuzzleTier.easy: [(side: 5, shape: LightsShape.plus, wrap: false, states: 2), (side: 5, shape: LightsShape.diagonal, wrap: false, states: 2), (side: 3, shape: LightsShape.plus, wrap: false, states: 3)],
    PuzzleTier.normal: [(side: 6, shape: LightsShape.plus, wrap: false, states: 2), (side: 4, shape: LightsShape.plus, wrap: true, states: 2), (side: 4, shape: LightsShape.plus, wrap: false, states: 3)],
    PuzzleTier.hard: [(side: 6, shape: LightsShape.diagonal, wrap: false, states: 2), (side: 6, shape: LightsShape.plus, wrap: false, states: 3), (side: 7, shape: LightsShape.plus, wrap: true, states: 2)],
    PuzzleTier.expert: [(side: 6, shape: LightsShape.diagonal, wrap: false, states: 3), (side: 7, shape: LightsShape.diagonal, wrap: true, states: 2), (side: 7, shape: LightsShape.plus, wrap: true, states: 3)],
  };
  // 每档预计用时的区间（秒）：落在难度分 3、4、5、6、7 各自的区间里，五档不重叠（专家从 250 起，再低难度分就和困难一样是 6）。
  static const _window = {PuzzleTier.entry: (38, 52), PuzzleTier.easy: (60, 80), PuzzleTier.normal: (96, 124), PuzzleTier.hard: (153, 176), PuzzleTier.expert: (250, 266)};

  // 出题：按种子挑这一档的一种题，从全亮开始随机挑几格、每格点一到「级数减 1」下，得到开局，所以一定解得开；
  // 再求最少点法，预计用时落在这一档的区间、用到的变体都起作用才用，不满足就重挑。挑几格从「全按满下数点也够区间下沿」起、
  // 到「每格一下就超区间上沿」止，有零空间的再往上放宽两倍维数（多点的格可能被更省的点法抵掉）。
  @override
  PuzzleDraw<LightsPuzzle, List<int>> generate(int seed, PuzzleTier tier) {
    final random = PuzzleRandom(seed);
    final kind = random.pick(_kinds[tier]!);
    final (least, most) = _window[tier]!;
    final count = kind.side * kind.side;
    final cells = [for (var cell = 0; cell < count; cell++) cell];
    final lit = LightsPuzzle(side: kind.side, cells: List.filled(count, kind.states - 1), shape: kind.shape, wrap: kind.wrap, states: kind.states);
    final slack = 2 * lightsSolutions(lit)!.basis.length;
    // 估下沿时差的级数按最多算（每下最多影响 5 格），估上沿时按 0 算，两头都只会放宽、不会漏掉进得了区间的格数。
    final fewest = [for (var pressed = 1; pressed <= count; pressed++) pressed].firstWhere((pressed) => _paced(lit, pressed, pressed * lit.lit, math.min(count, pressed * 5) * lit.lit) >= least);
    final widest = [for (var pressed = count; pressed >= 1; pressed--) pressed].firstWhere((pressed) => _paced(lit, pressed, pressed, 0) <= most);
    final presses = [for (var pressed = fewest; pressed <= math.min(count, widest + slack); pressed++) pressed];
    while (true) {
      final pressed = random.pick(presses);
      random.shuffle(cells);
      final board = [...lit.cells];
      for (final cell in cells.take(pressed)) {
        for (var time = 1 + random.nextInt(lit.lit); time > 0; time--) {
          lightsPress(lit, board, cell);
        }
      }
      final puzzle = lit.copyWith(cells: board);
      if (puzzle.allLit) continue;
      final solution = lightsSolve(puzzle)!;
      final seconds = _paced(puzzle, solution.toSet().length, solution.length, _missing(puzzle));
      if (seconds < least || seconds > most || !lightsMatters(puzzle, solution.length)) continue;
      return PuzzleDraw(puzzle, solution);
    }
  }

  @override
  bool solved(LightsPuzzle puzzle, List<int> answer) {
    if (answer.length > lightsMaxPresses) return false;
    final cells = lightsReplay(puzzle, answer);
    return cells != null && cells.every((state) => state == puzzle.lit);
  }

  // 预计用时：看题 6 秒加每格 0.25 秒、开局还差的每一级 0.4 秒（灭的灯越多越要细看），加最少点法里每一格要想多久（pace）、
  // 同一格多点的一下 1.5 秒。pace 从 3×3 十字两态的 5.5 秒起，边长每大 1 多 12%（要盯的灯多、追灯的路长），斜十字乘 1.35
  // （要重新想影响范围），环面乘 1.6（边上的格影响对边、逐行追灯走不通），三态乘 1.6（每格要算差几级、模 3 加减）。
  // 解不开的题面不会出、也解码不进来，按每格都点满算。
  @override
  int expectedSeconds(LightsPuzzle puzzle) {
    final presses = lightsSolve(puzzle);
    final count = puzzle.side * puzzle.side;
    if (presses == null) return _paced(puzzle, count, count * puzzle.lit, _missing(puzzle));
    return _paced(puzzle, presses.toSet().length, presses.length, _missing(puzzle));
  }

  // 开局离全亮还差几级（两态就是灭着几盏）。
  static int _missing(LightsPuzzle puzzle) => puzzle.cells.fold(0, (total, state) => total + puzzle.lit - state);

  static int _paced(LightsPuzzle puzzle, int distinct, int taps, int missing) {
    final pace = 5.5 * (1 + .12 * (puzzle.side - 3)) * (puzzle.shape == LightsShape.diagonal ? 1.35 : 1) * (puzzle.wrap ? 1.6 : 1) * (puzzle.states == 3 ? 1.6 : 1);
    return (6 + puzzle.side * puzzle.side * .25 + missing * .4 + distinct * pace + (taps - distinct) * 1.5).round();
  }

  // 难易分直接由预计用时定（同汉诺塔）：难度分（puzzleDifficulty）的每一档再对半分成两级，预计用时的区间对齐难度分 3–7，
  // 所以入门 1–2、简单 3–4、普通 5–6、困难 7–8、专家 9–10，五档分段不重叠。
  @override
  int complexity(LightsPuzzle puzzle) {
    final level = 1.4 * math.log(expectedSeconds(puzzle) / 10) / math.ln2;
    return ((level - 2.5) * 2).floor().clamp(0, 9) + 1;
  }

  // 题面编成边长、形状、环面、级数与一串数字（按行优先，每格的状态，级数减 1 是亮）。
  @override
  Object encodePuzzle(LightsPuzzle puzzle) => {'side': puzzle.side, 'shape': puzzle.shape.code, 'wrap': puzzle.wrap, 'states': puzzle.states, 'lights': puzzle.cells.join()};

  @override
  LightsPuzzle decodePuzzle(Object? json) {
    final side = puzzleInt(json, 'side', min: lightsMinSide, max: lightsMaxSide);
    final shape = puzzleInt(json, 'shape', min: 0, max: LightsShape.values.length - 1);
    final states = puzzleInt(json, 'states', min: 2, max: lightsMaxStates);
    final wrap = (json as Map)['wrap'], lights = json['lights'];
    if (wrap is! bool) throw const FormatException('题目字段 wrap 不合法');
    if (lights is! String || lights.length != side * side || !RegExp('^[0-${states - 1}]+\$').hasMatch(lights)) throw const FormatException('灯的状态不合法');
    final puzzle = LightsPuzzle(
      side: side,
      cells: [for (final char in lights.split('')) int.parse(char)],
      shape: LightsShape.values.firstWhere((value) => value.code == shape),
      wrap: wrap,
      states: states,
    );
    // 已经全亮的不是题；有的局面怎么点都点不全亮（如 4×4、5×5 十字两态的一大半），题库里不该有。
    if (puzzle.allLit || lightsSolutions(puzzle) == null) throw const FormatException('题面已经全亮或解不开');
    return puzzle;
  }

  // 答案是依次点的格（行优先下标），最长 lightsMaxPresses 下。
  @override
  Object encodeAnswer(List<int> answer) => [...answer];

  @override
  List<int> decodeAnswer(Object? json) => puzzleInts(json, maxLength: lightsMaxPresses, min: 0, max: lightsMaxSide * lightsMaxSide - 1);
}
