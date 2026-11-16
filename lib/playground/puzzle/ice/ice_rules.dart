import 'package:superxd/playground/puzzle_rules.dart';

// 冰面滑行：格子地图上有岩石，棋子朝一个方向滑出去，一直滑到撞上岩石或边界才停。
// 要正好停在终点格上才算到达，只是滑过去不算；滑不动（紧挨着岩石或边界）只算原地，不算违规。
class IcePuzzle {
  const IcePuzzle({required this.width, required this.height, required this.rocks, required this.start, required this.goal, this.exits = const []});
  final int width;
  final int height;
  // 按行优先，true 是岩石。
  final List<bool> rocks;
  final int start;
  final int goal;
  // 挑战里收碎片的关：棋盘上标 ①②③… 的几个出口（含终点），哪个是终点由碎片算出来（人工决策见 challenge_rules.dart），页面不标终点；平时为空。
  final List<int> exits;
}

// 挑战里一道题最多标几个出口。
const iceMaxExits = 4;

// 方向编码 0 上、1 右、2 下、3 左（答案按它存，发出后不改）。
const iceUp = 0, iceRight = 1, iceDown = 2, iceLeft = 3;
const iceDirections = 4;
const iceMinSide = 3;
const iceMaxSide = 16;
// 一局最多记这么多步（外部输入的上限；专家档最少十几步，留足走弯路的余地）。
const iceMaxMoves = 2048;

const _rowStep = [-1, 0, 1, 0];
const _columnStep = [0, 1, 0, -1];

// 从 cell 朝 direction 滑到停下的那一格；紧挨着岩石或边界时就是原地。
int iceSlide(IcePuzzle puzzle, int cell, int direction) {
  final width = puzzle.width;
  var row = cell ~/ width, column = cell % width;
  while (true) {
    final nextRow = row + _rowStep[direction], nextColumn = column + _columnStep[direction];
    if (nextRow < 0 || nextRow >= puzzle.height || nextColumn < 0 || nextColumn >= width || puzzle.rocks[nextRow * width + nextColumn]) return row * width + column;
    row = nextRow;
    column = nextColumn;
  }
}

// 从起点按序滑完，最后停在哪一格。
int iceReplay(IcePuzzle puzzle, Iterable<int> moves) => moves.fold(puzzle.start, (cell, direction) => iceSlide(puzzle, cell, direction));

// 广度优先搜索，状态是停下的位置：每格最少要滑几次才能停在那里（起点是 0，停不到的是 null），
// 顺带记下是从哪一格朝哪个方向滑来的，用来还原最短走法。
({List<int?> steps, List<int> previous, List<int> direction}) _search(IcePuzzle puzzle) {
  final cells = puzzle.width * puzzle.height;
  final steps = List<int?>.filled(cells, null), previous = List.filled(cells, -1), direction = List.filled(cells, -1);
  final queue = [puzzle.start];
  steps[puzzle.start] = 0;
  for (var head = 0; head < queue.length; head++) {
    final cell = queue[head];
    for (var move = 0; move < iceDirections; move++) {
      final stop = iceSlide(puzzle, cell, move);
      if (steps[stop] != null) continue;
      steps[stop] = steps[cell]! + 1;
      previous[stop] = cell;
      direction[stop] = move;
      queue.add(stop);
    }
  }
  return (steps: steps, previous: previous, direction: direction);
}

// 每格最少几步能停在那里（停不到是 null）。
List<int?> iceDistances(IcePuzzle puzzle) => _search(puzzle).steps;

int? iceMinMoves(IcePuzzle puzzle) => iceDistances(puzzle)[puzzle.goal];

// 一份最短走法；到不了终点返回 null。
List<int>? iceSolution(IcePuzzle puzzle) {
  final search = _search(puzzle);
  if (search.steps[puzzle.goal] == null) return null;
  final moves = <int>[];
  for (var cell = puzzle.goal; cell != puzzle.start; cell = search.previous[cell]) {
    moves.add(search.direction[cell]);
  }
  return moves.reversed.toList();
}

class IceRules extends PuzzleRules<IcePuzzle, List<int>> {
  const IceRules();

  // 挑战里的特性（[人工决策-2026-11-16 17:26:21] 见 puzzle_rules.dart 的 PuzzleRules.fragment）。
  @override
  int? fragment(IcePuzzle puzzle, List<int> solution) => iceMinMoves(puzzle);
  @override
  PuzzleIntake? get intake => PuzzleIntake.goal;
  @override
  int? minimum(IcePuzzle puzzle) => iceMinMoves(puzzle);

  static const _sides = {PuzzleTier.entry: 6, PuzzleTier.easy: 7, PuzzleTier.normal: 8, PuzzleTier.hard: 10, PuzzleTier.expert: 12};
  // 每档终点的最少步数区间（含两端）。
  static const _least = {PuzzleTier.entry: (3, 5), PuzzleTier.easy: (5, 7), PuzzleTier.normal: (7, 10), PuzzleTier.hard: (10, 14), PuzzleTier.expert: (14, 99)};

  // 出图：岩石按 15%–25% 的密度随机撒，起点随机取一格冰面；从起点广度优先搜一遍每个能停下的格要几步，
  // 在最少步数落在这一档区间的格里随机挑一个当终点（终点因此一定能停下、一定可解）；没有这样的格就换一张图。
  @override
  PuzzleDraw<IcePuzzle, List<int>> generate(int seed, PuzzleTier tier) {
    final side = _sides[tier]!;
    final (least, most) = _least[tier]!;
    final random = PuzzleRandom(seed);
    while (true) {
      final density = .15 + random.nextDouble() * .10;
      final rocks = [for (var index = 0; index < side * side; index++) random.chance(density)];
      final open = [for (var index = 0; index < rocks.length; index++) if (!rocks[index]) index];
      final start = random.pick(open);
      final steps = iceDistances(IcePuzzle(width: side, height: side, rocks: rocks, start: start, goal: start));
      final goals = [for (var index = 0; index < steps.length; index++) if (steps[index] case final count? when count >= least && count <= most) index];
      if (goals.isEmpty) continue;
      final puzzle = IcePuzzle(width: side, height: side, rocks: rocks, start: start, goal: random.pick(goals));
      return PuzzleDraw(puzzle, iceSolution(puzzle)!);
    }
  }

  @override
  bool solved(IcePuzzle puzzle, List<int> answer) => answer.length <= iceMaxMoves && iceReplay(puzzle, answer) == puzzle.goal;

  // 预计用时：入门约 30 秒、专家约 3 分钟（按常见的人工解题速度估），按这个游戏里的难易每高一级乘 1.33。
  @override
  int expectedSeconds(IcePuzzle puzzle) => puzzlePace(complexity(puzzle), base: 25, growth: 1.33);

  @override
  int complexity(IcePuzzle puzzle) => iceDifficulty(iceMinMoves(puzzle) ?? 99, puzzle.width > puzzle.height ? puzzle.width : puzzle.height);

  @override
  Object encodePuzzle(IcePuzzle puzzle) => {
    'width': puzzle.width,
    'height': puzzle.height,
    'rocks': puzzle.rocks.map((rock) => rock ? '1' : '0').join(),
    'start': puzzle.start,
    'goal': puzzle.goal,
    if (puzzle.exits.isNotEmpty) 'exits': [...puzzle.exits],
  };

  @override
  IcePuzzle decodePuzzle(Object? json) {
    final width = puzzleInt(json, 'width', min: iceMinSide, max: iceMaxSide), height = puzzleInt(json, 'height', min: iceMinSide, max: iceMaxSide);
    final cells = width * height;
    final text = (json as Map)['rocks'];
    if (text is! String || text.length != cells || !RegExp(r'^[01]*$').hasMatch(text)) throw const FormatException('岩石不合法');
    final rocks = [for (final char in text.split('')) char == '1'];
    final start = puzzleInt(json, 'start', min: 0, max: cells - 1), goal = puzzleInt(json, 'goal', min: 0, max: cells - 1);
    if (rocks[start] || rocks[goal] || start == goal) throw const FormatException('起点或终点不合法');
    final exits = json['exits'] == null ? const <int>[] : puzzleInts(json['exits'], maxLength: iceMaxExits, min: 0, max: cells - 1);
    if (exits.isNotEmpty && (exits.length < 2 || exits.toSet().length != exits.length || !exits.contains(goal) || exits.any((exit) => rocks[exit] || exit == start))) {
      throw const FormatException('出口不合法');
    }
    return IcePuzzle(width: width, height: height, rocks: rocks, start: start, goal: goal, exits: exits);
  }

  // 每步一个方向（0 上、1 右、2 下、3 左），最长 iceMaxMoves 步。
  @override
  Object encodeAnswer(List<int> answer) => [...answer];

  @override
  List<int> decodeAnswer(Object? json) => puzzleInts(json, maxLength: iceMaxMoves, min: 0, max: iceDirections - 1);
}

// 难易分 1–10：主要看最少步数（广度优先搜索的层数，也就是要往前想几步），地图边长做小幅加成（格多了要看的岩石多）。
// 系数让相邻两档在区间端点上也拉开：入门 1–2、简单 3、普通 4–5、困难 6–7、专家 8–10（步数到 19 封顶）。
int iceDifficulty(int least, int side) => (least * .42 + (side - 6) * .28 + .2).round().clamp(1, 10);

// 挑战里收碎片的关要标的几个出口：终点之外再挑几个停得到、最少要 3 步以上的格，互相隔开两格以上（挨着的一眼看不出差别）；
// 按种子挑、挑不够就少几个（至少 2 个才有得选）。返回包括终点在内、按格号排好的出口。
List<int> iceExits(IcePuzzle puzzle, PuzzleRandom random, {int count = 3}) {
  final steps = iceDistances(puzzle);
  int apart(int left, int right) => (left ~/ puzzle.width - right ~/ puzzle.width).abs() + (left % puzzle.width - right % puzzle.width).abs();
  final candidates = [for (var cell = 0; cell < steps.length; cell++) if ((steps[cell] ?? 0) >= 3 && cell != puzzle.goal && cell != puzzle.start) cell];
  random.shuffle(candidates);
  final exits = [puzzle.goal];
  for (final cell in candidates) {
    if (exits.length == count) break;
    if (exits.every((exit) => apart(exit, cell) >= 2)) exits.add(cell);
  }
  return exits..sort();
}
