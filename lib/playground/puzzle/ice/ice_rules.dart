import 'dart:typed_data';

import 'package:superxd/playground/puzzle_rules.dart';

// 冰面滑行：格子地图上小企鹅朝一个方向滑出去，一直滑到停下：撞上岩石或边界停在它前面一格，滑进雪地停在雪上；
// 滑进冰洞就掉下去（这一局失败，可撤销）。宝石滑过或停在上面就收走；薄冰同冰面一样滑过，但滑过或停过一次就碎成冰洞。
// 步数有上限，走满了还没解开这一局失败（可撤销）。收齐全部宝石后正好停在终点上才算解开，只是滑过去不算；
// 滑不动（紧挨着岩石或边界）只算原地，不算违规。
// 11-16 深改（题面写法第 2 版）：用户反馈太简单，只看停没停在终点、岩石随机撒、自由模式不限步，乱滑也能到。参照业界的冰面谜题
// （宝可梦冰面、Ice Slide、Club Penguin 薄冰）逐档加机制与步数上限（每档参数在 IceRules._plans），困难与专家另用乱走成功率
// iceWanderOdds 挡住「乱走也能到」的题。
// 一格是什么：题面按格写成一位数字，数字就是 index（发出后不改，只能在末尾追加）。
enum IceTile { ice, rock, snow, hole, thin }

class IcePuzzle {
  IcePuzzle({required this.width, required this.height, required this.tiles, this.gems = const [], required this.start, required this.goal, required this.limit, this.exits = const []})
    : thin = [for (var cell = 0; cell < tiles.length; cell++) if (tiles[cell] == IceTile.thin) cell];
  final int width;
  final int height;
  // 按行优先每格是什么。
  final List<IceTile> tiles;
  // 宝石所在的格（升序，都在冰面上）；收没收按这里的下标记成位。
  final List<int> gems;
  final int start;
  final int goal;
  // 步数上限（含）：走满了还没解开，这一局失败。
  final int limit;
  // 挑战里收碎片的关：棋盘上标 ①②③… 的几个出口（含终点），哪个是终点由碎片算出来（人工决策见 challenge_rules.dart），页面不标终点；平时为空。
  final List<int> exits;
  // 薄冰所在的格（升序，从 tiles 推出）；碎没碎按这里的下标记成位。
  final List<int> thin;

  int get allGems => (1 << gems.length) - 1;

  // 换掉几项，其余不变（挑战的出口、出题时查机制起不起作用）。
  IcePuzzle copyWith({List<IceTile>? tiles, List<int>? gems, int? goal, int? limit, List<int>? exits}) =>
      IcePuzzle(width: width, height: height, tiles: tiles ?? this.tiles, gems: gems ?? this.gems, start: start, goal: goal ?? this.goal, limit: limit ?? this.limit, exits: exits ?? this.exits);
}

// 一局走到哪了：棋子在哪一格（掉下去时是掉进去的那一格）、收了哪几颗宝石（按 IcePuzzle.gems 的下标记成位）、
// 碎了哪几块薄冰（按 IcePuzzle.thin 的下标记成位：滑过或停过的都算，棋子脚下那块离开时才真成冰洞）、掉没掉下去。
class IceState {
  const IceState(this.cell, {this.gems = 0, this.broken = 0, this.fallen = false});
  final int cell;
  final int gems;
  final int broken;
  final bool fallen;
}

// 挑战里一道题最多标几个出口。
const iceMaxExits = 4;

// 方向编码 0 上、1 右、2 下、3 左（答案按它存，发出后不改）。
const iceUp = 0, iceRight = 1, iceDown = 2, iceLeft = 3;
const iceDirections = 4;
const iceMinSide = 3;
const iceMaxSide = 16;
// 一局最多记这么多步（外部输入的上限；题面的步数上限也不超过它）。
const iceMaxMoves = 2048;
// 一道题最多几颗宝石、几块薄冰：求解器的状态是（位置、收了哪几颗、碎了哪几块），16×16 也不过 256 × 2^3 × 2^6 个；外部题面按同一上限收。
const iceMaxGems = 3;
const iceMaxThin = 6;

const _rowStep = [-1, 0, 1, 0];
const _columnStep = [0, 1, 0, -1];

// 从 state 朝 direction 滑一次：滑到撞上岩石或边界、滑进雪地为止；路上（含停下的那格）的宝石收走、薄冰记成碎了；
// 路上碰到冰洞或碎了的薄冰就掉下去（cell 是那一格）。紧挨着岩石或边界时滑不动，原样返回（不算违规）。
IceState iceMove(IcePuzzle puzzle, IceState state, int direction) {
  final width = puzzle.width;
  var row = state.cell ~/ width, column = state.cell % width;
  var gems = state.gems, broken = state.broken, moved = false;
  while (true) {
    final nextRow = row + _rowStep[direction], nextColumn = column + _columnStep[direction];
    if (nextRow < 0 || nextRow >= puzzle.height || nextColumn < 0 || nextColumn >= width) break;
    final next = nextRow * width + nextColumn;
    final tile = puzzle.tiles[next];
    if (tile == IceTile.rock) break;
    final thin = tile == IceTile.thin ? puzzle.thin.indexOf(next) : -1;
    if (tile == IceTile.hole || (thin >= 0 && broken & (1 << thin) != 0)) return IceState(next, gems: gems, broken: broken, fallen: true);
    row = nextRow;
    column = nextColumn;
    moved = true;
    final gem = puzzle.gems.indexOf(next);
    if (gem >= 0) gems |= 1 << gem;
    if (thin >= 0) broken |= 1 << thin;
    if (tile == IceTile.snow) break;
  }
  return moved ? IceState(row * width + column, gems: gems, broken: broken) : state;
}

// 从起点按序滑完（掉下去就停在掉下去的那一刻）。
IceState iceReplay(IcePuzzle puzzle, Iterable<int> moves) {
  var state = IceState(puzzle.start);
  for (final direction in moves) {
    state = iceMove(puzzle, state, direction);
    if (state.fallen) break;
  }
  return state;
}

// 到了：没掉下去、宝石收齐、停在终点。
bool iceArrived(IcePuzzle puzzle, IceState state) => !state.fallen && state.cell == puzzle.goal && state.gems == puzzle.allGems;

// 求解用的图：每格朝每个方向从「什么都没碎」滑一次的结果（停在哪、掉没掉、路上的宝石位与薄冰位）。路上的薄冰（含停下的那格）
// 已经碎了就是掉下去，所以任何局面的一步都能由它直接算出，广度优先时不用再逐格走。
// 局面编号 = (碎了的薄冰位 << 宝石数 | 宝石位) × 格数 + 格。
class _IceGraph {
  _IceGraph(this.puzzle)
    : cells = puzzle.width * puzzle.height,
      stops = Int32List(puzzle.width * puzzle.height * iceDirections),
      gems = Int32List(puzzle.width * puzzle.height * iceDirections),
      thin = Int32List(puzzle.width * puzzle.height * iceDirections) {
    for (var cell = 0; cell < cells; cell++) {
      for (var direction = 0; direction < iceDirections; direction++) {
        final ray = cell * iceDirections + direction;
        final from = IceState(cell), to = iceMove(puzzle, from, direction);
        stops[ray] = to.fallen ? _fall : identical(to, from) ? _stuck : to.cell;
        gems[ray] = to.gems;
        thin[ray] = to.broken;
      }
    }
  }

  static const _stuck = -1, _fall = -2;
  final IcePuzzle puzzle;
  final int cells;
  final Int32List stops, gems, thin;

  int get gemBits => puzzle.gems.length;
  int get states => cells << (puzzle.gems.length + puzzle.thin.length);
  int get start => puzzle.start;
  int cellOf(int state) => state % cells;
  int gemsOf(int state) => (state ~/ cells) & ((1 << gemBits) - 1);
  bool arrived(int state) => cellOf(state) == puzzle.goal && gemsOf(state) == puzzle.allGems;

  // 局面 state 朝 direction 走一步到的局面：滑不动是 -1，掉下去是 -2。
  int next(int state, int direction) {
    final cell = state % cells, marks = state ~/ cells;
    final ray = cell * iceDirections + direction, stop = stops[ray];
    if (stop < 0) return stop;
    final broken = marks >> gemBits;
    if (thin[ray] & broken != 0) return _fall;
    return ((broken | thin[ray]) << gemBits | (marks & ((1 << gemBits) - 1)) | gems[ray]) * cells + stop;
  }
}

// 从起点广度优先搜一遍全部局面：每个局面最少几步（到不了是 -1）、从哪个局面朝哪个方向来的（还原最短走法）。
({_IceGraph graph, Int32List steps, Int32List previous, Int8List direction}) _search(IcePuzzle puzzle) {
  final graph = _IceGraph(puzzle);
  final steps = Int32List(graph.states)..fillRange(0, graph.states, -1);
  final previous = Int32List(graph.states), direction = Int8List(graph.states);
  final queue = Int32List(graph.states);
  var tail = 0;
  queue[tail++] = graph.start;
  steps[graph.start] = 0;
  for (var head = 0; head < tail; head++) {
    final state = queue[head];
    for (var move = 0; move < iceDirections; move++) {
      final next = graph.next(state, move);
      if (next < 0 || steps[next] >= 0) continue;
      steps[next] = steps[state] + 1;
      previous[next] = state;
      direction[next] = move;
      queue[tail++] = next;
    }
  }
  return (graph: graph, steps: steps, previous: previous, direction: direction);
}

// 每格最少几步能收齐宝石并停在那里（停不到是 null）：出题挑终点、挑战挑出口都按它。
List<int?> iceDistances(IcePuzzle puzzle) {
  final search = _search(puzzle);
  final graph = search.graph, cells = graph.cells;
  final best = List<int?>.filled(cells, null);
  for (var state = 0; state < graph.states; state++) {
    final steps = search.steps[state];
    if (steps < 0 || graph.gemsOf(state) != puzzle.allGems) continue;
    final cell = state % cells;
    if (best[cell] == null || steps < best[cell]!) best[cell] = steps;
  }
  return best;
}

int? iceMinMoves(IcePuzzle puzzle) => iceDistances(puzzle)[puzzle.goal];

// 一份最短走法（宝石收齐、停在终点）；到不了返回 null。
List<int>? iceSolution(IcePuzzle puzzle) {
  final search = _search(puzzle);
  final graph = search.graph;
  int? end;
  for (var state = 0; state < graph.states; state++) {
    if (search.steps[state] >= 0 && graph.arrived(state) && (end == null || search.steps[state] < search.steps[end])) end = state;
  }
  if (end == null) return null;
  final moves = <int>[];
  for (var state = end; state != graph.start; state = search.previous[state]) {
    moves.add(search.direction[state]);
  }
  return moves.reversed.toList();
}

// 乱走成功率：挡住「乱走也能到」的指标（出题时每档要压到 _Plan.odds 以下，困难与专家压得很低）。
// 乱走的人不看全局、只避开眼前的冰洞：每一步在「滑得动、又不会掉下去」的方向里等可能地挑一个（一个都没有就卡死，算失败），
// 走到步数上限为止，途中收齐宝石停上终点即成功（解开就不再走）。按局面逐步精确累加概率、不抽样，同一道题算出的数一样。
double iceWanderOdds(IcePuzzle puzzle) {
  final graph = _IceGraph(puzzle);
  var current = {graph.start: 1.0};
  var success = 0.0;
  final options = List.filled(iceDirections, 0);
  for (var step = 0; step < puzzle.limit && current.isNotEmpty; step++) {
    final next = <int, double>{};
    for (final MapEntry(key: state, value: odds) in current.entries) {
      var count = 0;
      for (var move = 0; move < iceDirections; move++) {
        final to = graph.next(state, move);
        if (to >= 0) options[count++] = to;
      }
      for (var option = 0; option < count; option++) {
        final to = options[option], share = odds / count;
        if (graph.arrived(to)) {
          success += share;
        } else {
          next[to] = (next[to] ?? 0) + share;
        }
      }
    }
    current = next;
  }
  return success;
}

// 每档的出题参数：边长、终点最少步数区间（含两端）、步数上限比最少多几步、雪地、冰洞与薄冰的块数区间、宝石颗数区间与乱走成功率的上限。
class _Plan {
  const _Plan({required this.side, required this.least, required this.slack, this.snow = (0, 0), this.holes = (0, 0), this.gems = (0, 0), this.thin = (0, 0), this.odds = 1});
  final int side;
  final (int, int) least;
  final int slack;
  final (int, int) snow, holes, gems, thin;
  final double odds;
}

class IceRules extends PuzzleRules<IcePuzzle, List<int>> {
  const IceRules();

  // 题面写法第 2 版（11-16）：加了雪地、冰洞、薄冰（tiles 一格一位数字）、宝石与步数上限；第 1 版的判定留在服务端给没更新的应用。
  @override
  int get puzzleVersion => 2;

  // 挑战里的特性（[人工决策-2026-11-16 17:26:21] 见 puzzle_rules.dart 的 PuzzleRules.fragment）。
  @override
  int? fragment(IcePuzzle puzzle, List<int> solution) => iceMinMoves(puzzle);
  @override
  PuzzleIntake? get intake => PuzzleIntake.goal;
  @override
  int? minimum(IcePuzzle puzzle) => iceMinMoves(puzzle);

  // 逐档加机制：入门只有岩石；简单加雪地；普通加冰洞；困难加宝石（先收齐）；专家再加薄冰。步数上限逐档收紧，困难起就是最少步数。
  static const _plans = {
    PuzzleTier.entry: _Plan(side: 6, least: (3, 5), slack: 4),
    PuzzleTier.easy: _Plan(side: 7, least: (5, 7), slack: 2, snow: (2, 4)),
    PuzzleTier.normal: _Plan(side: 8, least: (7, 10), slack: 1, snow: (2, 3), holes: (3, 5), odds: .02),
    PuzzleTier.hard: _Plan(side: 10, least: (9, 14), slack: 0, snow: (2, 4), holes: (4, 7), gems: (1, 2), odds: .001),
    PuzzleTier.expert: _Plan(side: 12, least: (12, 20), slack: 0, snow: (3, 5), holes: (5, 8), gems: (2, 3), thin: (4, 6), odds: .0001),
  };

  // 出图：岩石按 15%–25% 的密度随机撒，起点随机取一格冰面，雪地与冰洞再撒在冰面上（不压起点）；薄冰与宝石只放在从起点滑得到的路上
  // （不然踩不到、收不到）。广度优先搜一遍每格收齐宝石后最少几步停得下，在落在这一档区间的格里随机挑终点，步数上限 = 最少步数 + slack。
  // 再查新加的机制真的起作用（_matters）与乱走成功率，不合格就换一张图。
  @override
  PuzzleDraw<IcePuzzle, List<int>> generate(int seed, PuzzleTier tier) {
    final plan = _plans[tier]!;
    final side = plan.side, cells = side * side;
    final random = PuzzleRandom(seed);
    int count((int, int) range) => range.$1 + random.nextInt(range.$2 - range.$1 + 1);
    // 最少步数先在区间里等可能地定下，再换图直到有这个步数的终点（直接按格挑会扎堆在区间的低端：步数越多停得下的格越少）。
    final target = count(plan.least);
    while (true) {
      final density = .15 + random.nextDouble() * .10;
      final tiles = [for (var index = 0; index < cells; index++) random.chance(density) ? IceTile.rock : IceTile.ice];
      final open = [for (var index = 0; index < cells; index++) if (tiles[index] == IceTile.ice) index];
      final start = random.pick(open);
      open.remove(start);
      random.shuffle(open);
      for (final (tile, range) in [(IceTile.snow, plan.snow), (IceTile.hole, plan.holes)]) {
        for (var placed = count(range); placed > 0 && open.isNotEmpty; placed--) {
          tiles[open.removeLast()] = tile;
        }
      }
      final paths = _paths(IcePuzzle(width: side, height: side, tiles: tiles, start: start, goal: start, limit: iceMaxMoves))..remove(start);
      final lanes = [for (final cell in paths) if (tiles[cell] == IceTile.ice) cell];
      random.shuffle(lanes);
      final thin = count(plan.thin), gemCount = count(plan.gems);
      if (lanes.length < thin + gemCount) continue;
      for (final cell in lanes.sublist(0, thin)) {
        tiles[cell] = IceTile.thin;
      }
      final gems = lanes.sublist(thin, thin + gemCount)..sort();
      final layout = IcePuzzle(width: side, height: side, tiles: tiles, gems: gems, start: start, goal: start, limit: iceMaxMoves);
      final steps = iceDistances(layout);
      final goals = [
        for (var cell = 0; cell < cells; cell++)
          if (steps[cell] == target && _landing(tiles[cell]) && !gems.contains(cell)) cell,
      ];
      if (goals.isEmpty) continue;
      final goal = random.pick(goals);
      final puzzle = layout.copyWith(goal: goal, limit: target + plan.slack);
      if (!_matters(puzzle, target)) continue;
      if (plan.odds < 1 && iceWanderOdds(puzzle) > plan.odds) continue;
      return PuzzleDraw(puzzle, iceSolution(puzzle)!);
    }
  }

  // 新加的机制都要起作用：雪地、宝石、薄冰各自换回冰面（宝石拿掉）后，最少步数要变（雪地）或变少（宝石要绕路、薄冰逼着换走法）；
  // 冰洞不单查（只要在路上就是陷阱，乱走成功率管它）。
  static bool _matters(IcePuzzle puzzle, int least) {
    int? without(IceTile tile) => iceMinMoves(puzzle.copyWith(tiles: [for (final each in puzzle.tiles) each == tile ? IceTile.ice : each]));
    if (puzzle.tiles.contains(IceTile.snow) && without(IceTile.snow) == least) return false;
    if (puzzle.thin.isNotEmpty && (without(IceTile.thin) ?? least) >= least) return false;
    if (puzzle.gems.isNotEmpty && (iceMinMoves(puzzle.copyWith(gems: const [])) ?? least) >= least) return false;
    return true;
  }

  @override
  bool solved(IcePuzzle puzzle, List<int> answer) => answer.length <= puzzle.limit && iceArrived(puzzle, iceReplay(puzzle, answer));

  // 预计用时：入门约 40 秒、专家约 4 分半（按常见的人工解题速度估），按这个游戏里的难易每高一级乘 1.27。
  @override
  int expectedSeconds(IcePuzzle puzzle) => puzzlePace(complexity(puzzle), base: 32, growth: 1.27);

  @override
  int complexity(IcePuzzle puzzle) => iceDifficulty(puzzle);

  @override
  Object encodePuzzle(IcePuzzle puzzle) => {
    'width': puzzle.width,
    'height': puzzle.height,
    'tiles': puzzle.tiles.map((tile) => tile.index).join(),
    'gems': [...puzzle.gems],
    'start': puzzle.start,
    'goal': puzzle.goal,
    'limit': puzzle.limit,
    if (puzzle.exits.isNotEmpty) 'exits': [...puzzle.exits],
  };

  // 外部输入的边界：格子串只认 0–4，起点在冰面上，终点与出口在冰面或雪地上、不压起点与宝石，宝石在冰面上、升序不重复，
  // 宝石与薄冰不超过上限，步数上限在 1 到 iceMaxMoves 之间且这一局在上限内解得开。
  @override
  IcePuzzle decodePuzzle(Object? json) {
    final width = puzzleInt(json, 'width', min: iceMinSide, max: iceMaxSide), height = puzzleInt(json, 'height', min: iceMinSide, max: iceMaxSide);
    final cells = width * height;
    final text = (json as Map)['tiles'];
    if (text is! String || text.length != cells || !RegExp(r'^[0-4]*$').hasMatch(text)) throw const FormatException('格子不合法');
    final tiles = [for (final char in text.codeUnits) IceTile.values[char - 0x30]];
    if (tiles.where((tile) => tile == IceTile.thin).length > iceMaxThin) throw const FormatException('薄冰太多');
    final start = puzzleInt(json, 'start', min: 0, max: cells - 1), goal = puzzleInt(json, 'goal', min: 0, max: cells - 1);
    final gems = puzzleInts(json['gems'], maxLength: iceMaxGems, min: 0, max: cells - 1);
    for (var index = 0; index < gems.length; index++) {
      if (tiles[gems[index]] != IceTile.ice || (index > 0 && gems[index] <= gems[index - 1]) || gems[index] == start || gems[index] == goal) throw const FormatException('宝石不合法');
    }
    if (tiles[start] != IceTile.ice || !_landing(tiles[goal]) || start == goal) throw const FormatException('起点或终点不合法');
    final limit = puzzleInt(json, 'limit', min: 1, max: iceMaxMoves);
    final exits = json['exits'] == null ? const <int>[] : puzzleInts(json['exits'], maxLength: iceMaxExits, min: 0, max: cells - 1);
    if (exits.isNotEmpty && (exits.length < 2 || exits.toSet().length != exits.length || !exits.contains(goal) || exits.any((exit) => !_landing(tiles[exit]) || exit == start || gems.contains(exit)))) {
      throw const FormatException('出口不合法');
    }
    final puzzle = IcePuzzle(width: width, height: height, tiles: tiles, gems: gems, start: start, goal: goal, limit: limit, exits: exits);
    if ((iceMinMoves(puzzle) ?? limit + 1) > limit) throw const FormatException('步数上限内解不开');
    return puzzle;
  }

  // 每步一个方向（0 上、1 右、2 下、3 左），最长 iceMaxMoves 步。
  @override
  Object encodeAnswer(List<int> answer) => [...answer];

  @override
  List<int> decodeAnswer(Object? json) => puzzleInts(json, maxLength: iceMaxMoves, min: 0, max: iceDirections - 1);
}

// 停得下的格里能当终点与出口的：冰面与雪地（薄冰停一下就碎，不当终点）。
bool _landing(IceTile tile) => tile == IceTile.ice || tile == IceTile.snow;

// 从起点滑得到的路：所有停得下的局面朝四个方向滑一次经过（含停下）的格，不看宝石与薄冰。
Set<int> _paths(IcePuzzle puzzle) {
  final search = _search(puzzle);
  final graph = search.graph, cells = <int>{};
  for (var state = 0; state < graph.states; state++) {
    if (search.steps[state] < 0) continue;
    for (var direction = 0; direction < iceDirections; direction++) {
      var at = IceState(state % graph.cells);
      final to = iceMove(puzzle, at, direction);
      if (identical(to, at) || to.fallen) continue;
      // 沿这一趟逐格记下（iceMove 只给终点）。
      while (at.cell != to.cell) {
        final step = at.cell + _rowStep[direction] * puzzle.width + _columnStep[direction];
        cells.add(step);
        at = IceState(step);
      }
    }
  }
  return cells;
}

// 难易分 1–10（只在本游戏里排难易）：先看用到第几层机制（只有岩石、加雪地、加冰洞、加宝石、加薄冰，同出题的逐档加法），每层占两分；
// 层内再看最少步数在这一层的步数区间里走到了哪（_spans，同各档区间），过了 _deepAt 就加 1。五档因此分段不重叠：入门 1–2、简单 3–4、普通 5–6、困难 7–8、专家 9–10。
int iceDifficulty(IcePuzzle puzzle) {
  final level = puzzle.thin.isNotEmpty ? 4 : puzzle.gems.isNotEmpty ? 3 : puzzle.tiles.contains(IceTile.hole) ? 2 : puzzle.tiles.contains(IceTile.snow) ? 1 : 0;
  final (low, high) = _spans[level];
  final least = iceMinMoves(puzzle) ?? high;
  return 2 * level + 1 + ((least - low) >= (high - low) * _deepAt ? 1 : 0);
}

const _spans = [(3, 5), (5, 7), (7, 10), (9, 14), (12, 20)];
const _deepAt = .3;

// 挑战里收碎片的关要标的几个出口：终点之外再挑几个停得到、收齐宝石后最少步数与终点相同的格（步数上限因此对每个出口都一样，
// 服务器换终点不用改上限；碎片也都一样），互相隔开两格以上（挨着的一眼看不出差别），不压起点与宝石；按种子挑、挑不够就少几个
// （至少 2 个才有得选）。返回包括终点在内、按格号排好的出口。
List<int> iceExits(IcePuzzle puzzle, PuzzleRandom random, {int count = 3}) {
  final steps = iceDistances(puzzle);
  final least = steps[puzzle.goal];
  int apart(int left, int right) => (left ~/ puzzle.width - right ~/ puzzle.width).abs() + (left % puzzle.width - right % puzzle.width).abs();
  final candidates = [
    for (var cell = 0; cell < steps.length; cell++)
      if (steps[cell] == least && cell != puzzle.goal && cell != puzzle.start && _landing(puzzle.tiles[cell]) && !puzzle.gems.contains(cell)) cell,
  ];
  random.shuffle(candidates);
  final exits = [puzzle.goal];
  for (final cell in candidates) {
    if (exits.length == count) break;
    if (exits.every((exit) => apart(exit, cell) >= 2)) exits.add(cell);
  }
  return exits..sort();
}
