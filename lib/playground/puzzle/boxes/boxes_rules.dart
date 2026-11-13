import 'dart:collection';
import 'dart:typed_data';

import 'package:superxd/playground/puzzle_rules.dart';

// 推箱子：墙围起来的房间里有几个箱子和同样多的目标点。玩家每步上下左右走一格，走进箱子就把它朝前推一格；
// 只能推、不能拉，一次只推一个：箱子前面是墙或另一个箱子就推不动，这一步原地不动、不算违规。全部箱子都在目标点上即解开。
class BoxesPuzzle {
  const BoxesPuzzle({required this.width, required this.height, required this.walls, required this.goals, required this.boxes, required this.player});
  // 整张图的宽高，含外圈的墙。
  final int width;
  final int height;
  // 按行优先，true 是墙；出了图的边界同样算墙。
  final List<bool> walls;
  // 目标点与箱子所在的格（升序，数目相同、各自不重叠）。
  final List<int> goals;
  final List<int> boxes;
  final int player;
}

// 方向编码 0 上、1 右、2 下、3 左（答案按它存，发出后不改）。
const boxesUp = 0, boxesRight = 1, boxesDown = 2, boxesLeft = 3;
const boxesDirections = 4;
const boxesMinSide = 3;
const boxesMaxSide = 16;
// 箱子最多 5 个：求解器把箱子位置按每格 8 位拼成一个整数作状态键，5 个加玩家共 48 位，换到 53 位精度的 JS 整数也放得下。
const boxesMaxBoxes = 5;
// 一局最多记这么多步（外部输入的上限；专家档的参考走法一两百步，留足走弯路与撤销重走的余地）。
const boxesMaxMoves = 4096;
// 求解器最多展开这么多个状态：外部的题超了按解不开算（难度分记满）。出的题实测最多展开一万上下。
const boxesSolveLimit = 60000;

const _rowStep = [-1, 0, 1, 0];
const _columnStep = [0, 1, 0, -1];

// 从 cell 朝 direction 走一格到哪一格；出了图或是墙返回 null。
int? boxesNeighbor(BoxesPuzzle puzzle, int cell, int direction) {
  final row = cell ~/ puzzle.width + _rowStep[direction], column = cell % puzzle.width + _columnStep[direction];
  if (row < 0 || row >= puzzle.height || column < 0 || column >= puzzle.width) return null;
  final next = row * puzzle.width + column;
  return puzzle.walls[next] ? null : next;
}

// 玩家在 player、箱子在 boxes（顺序不限）时朝 direction 走一步：返回走到的格与被推的箱子在 boxes 里的下标（没推是 -1）；
// 撞墙、或箱子前面是墙或另一个箱子推不动时返回 null（原地不动）。只算不改，调用方自己挪。
({int to, int box})? boxesStep(BoxesPuzzle puzzle, List<int> boxes, int player, int direction) {
  final to = boxesNeighbor(puzzle, player, direction);
  if (to == null) return null;
  final box = boxes.indexOf(to);
  if (box < 0) return (to: to, box: -1);
  final beyond = boxesNeighbor(puzzle, to, direction);
  if (beyond == null || boxes.contains(beyond)) return null;
  return (to: to, box: box);
}

// 从开局按序走完：走不动的步原地不动。返回最后玩家的位置、箱子的位置（按开局的顺序）与推了几次。
({int player, List<int> boxes, int pushes}) boxesReplay(BoxesPuzzle puzzle, Iterable<int> moves) {
  final boxes = [...puzzle.boxes];
  var player = puzzle.player, pushes = 0;
  for (final direction in moves) {
    final step = boxesStep(puzzle, boxes, player, direction);
    if (step == null) continue;
    if (step.box >= 0) {
      boxes[step.box] = boxesNeighbor(puzzle, step.to, direction)!;
      pushes++;
    }
    player = step.to;
  }
  return (player: player, boxes: boxes, pushes: pushes);
}

bool boxesAllHome(BoxesPuzzle puzzle, List<int> boxes) => boxes.every(puzzle.goals.contains);

// 求解结果：一份走法（每步一个方向）、最少推几次，以及求解器为此展开了多少个状态（难度分用）。
class BoxesSolution {
  const BoxesSolution({required this.moves, required this.pushes, required this.expanded});
  final List<int> moves;
  final int pushes;
  final int expanded;
}

// 正向求最少推数：A* 搜索，状态是「箱子位置集合 + 玩家能走到的区域」（区域取能走到的最小格号作代表，只走不推算同一个状态），
// 每推一次代价 1；估价是每个箱子到最近目标点的推送距离之和（不看别的箱子，只会少估，所以第一次取出终局时推数最少）。
// 箱子推进「怎么推都到不了任何目标点」的死格、或和墙与别的箱子挤成 2×2 死块（里面有箱子不在目标点上）时剪掉。
// 展开超过 limit 个状态还没解开、或确实解不开都返回 null。
BoxesSolution? boxesSolve(BoxesPuzzle puzzle, {int limit = boxesSolveLimit}) {
  final board = _Board(puzzle.width, puzzle.height, puzzle.walls, puzzle.goals);
  final search = board.forward(puzzle.boxes, puzzle.player, limit);
  if (search == null) return null;
  return BoxesSolution(moves: board.expand(puzzle.boxes, puzzle.player, search.pushes), pushes: search.pushes.length, expanded: search.expanded);
}

// 一种档位的出题参数：房间内部边长、箱子数与最少推数的区间（都含两端）、内部墙块的占比区间、倒推最多收几个局面。
typedef _Shape = ({int inner, (int, int) boxes, (int, int) least, (double, double) density, int reverseLimit});

class BoxesRules extends PuzzleRules<BoxesPuzzle, List<int>> {
  const BoxesRules();

  // 区间与参数按实测定（11-12 每档 200 个种子）：
  // - 最少推数的区间档与档之间不重叠。各档房间不限推数时最深能倒到：入门 3–9（中位 5）、简单 3–19（中位 9）、普通中位约 15、
  //   困难中位约 20、专家中位约 27；区间下沿取在中位附近，倒不到的房间整张换掉（专家平均两三张出一道），上沿以上的房间取上沿那一层。
  // - 专家上沿压到 40：再深的参考走法要四五百步，手机上推完太久。
  // - 墙块占比试过整体再加一成：房间更像走廊，但能放箱子的格少了，反而倒不深，所以只比小房间略高。
  // - 倒推上限：专家 9×9 四个箱子的局面最多，上限内倒不到区间就换房间；实测每档 200 道都没碰到出不来题的情况。
  static const _tiers = <PuzzleTier, _Shape>{
    PuzzleTier.entry: (inner: 5, boxes: (1, 1), least: (4, 8), density: (.14, .24), reverseLimit: 3000),
    PuzzleTier.easy: (inner: 6, boxes: (2, 2), least: (9, 13), density: (.14, .24), reverseLimit: 8000),
    PuzzleTier.normal: (inner: 7, boxes: (2, 3), least: (14, 19), density: (.16, .26), reverseLimit: 12000),
    PuzzleTier.hard: (inner: 8, boxes: (3, 3), least: (20, 26), density: (.18, .28), reverseLimit: 16000),
    PuzzleTier.expert: (inner: 9, boxes: (3, 4), least: (27, 40), density: (.2, .3), reverseLimit: 20000),
  };

  // 出题（倒推法）：
  // 1. 随机挖一个连通的房间：矩形外圈是墙，随机切掉几个角，再往里随机摆几块墙（单格、两三格的条、L 形），
  //    每摆一块都要求地面仍然连通、没有三面是墙的死角，墙铺到这一档的占比为止；有 3×3 空地（太空旷）的房间换一张。
  // 2. 随机挑几格当目标点，彼此相距不超过两格（目标点扎堆，推进去要讲先后，同样的房间能倒得更深）；
  //    不挑角落那种箱子一放上去就拉不出来的格。箱子先放在目标点上。
  // 3. 从「箱子全在目标点上、玩家在任意一块区域」出发，广度优先地倒着「拉箱子」：玩家站在箱子一侧、朝反方向退一格并把箱子拉过来。
  //    倒推的每一步都能原样推回去，所以拉到的每个局面都可解；广度优先第一次拉到某个局面时的层数，就是它的最少推数
  //    （倒推本身就是一个按推数分层的完整搜索，所以不再从开局正着求一遍：正向 A* 在专家档要多花四成时间。
  //    测试里每道题都拿正向求解器 boxesSolve 核对过最少推数一致）。局面数超过这一档的上限还没倒到区间，就换一张房间。
  // 4. 在层数落在这一档区间里的局面中挑最深的一层，随机取一个合格的（每个箱子都得挪，且不是每个箱子各自一推到底），
  //    玩家放在它那块区域里随机一格。
  // 5. 顺着倒推链正着推回去，展开成每步的走法作参考解，按规则重放确认推得回去（推不回去就换一道）。
  @override
  PuzzleDraw<BoxesPuzzle, List<int>> generate(int seed, PuzzleTier tier) {
    final shape = _tiers[tier]!;
    final (low, high) = shape.least;
    final random = PuzzleRandom(seed);
    final side = shape.inner + 2;
    while (true) {
      final walls = _room(random, shape);
      final count = shape.boxes.$1 + random.nextInt(shape.boxes.$2 - shape.boxes.$1 + 1);
      final open = _Board(side, side, walls, const []);
      final spots = [for (var cell = 0; cell < side * side; cell++) if (!walls[cell] && open.pullable(cell)) cell];
      if (spots.length < count * 3) continue;
      random.shuffle(spots);
      final goals = [spots.first];
      for (final spot in spots.skip(1)) {
        if (goals.length == count) break;
        if (goals.any((goal) => (goal ~/ side - spot ~/ side).abs() + (goal % side - spot % side).abs() <= 2)) goals.add(spot);
      }
      if (goals.length < count) continue;
      goals.sort();
      final board = _Board(side, side, walls, goals);
      final picked = board.reverse(random, low, high, shape.reverseLimit);
      if (picked == null) continue;
      final puzzle = BoxesPuzzle(width: side, height: side, walls: walls, goals: goals, boxes: picked.boxes, player: picked.player);
      final moves = board.expand(picked.boxes, picked.player, picked.pushes);
      if (!solved(puzzle, moves)) continue;
      return PuzzleDraw(puzzle, moves);
    }
  }

  // 一张房间：外圈是墙，切角、摆墙块，直到墙占内部的比例到这一档的区间；不合格（不连通、有死角、太空旷、地面太少）换一张。
  static List<bool> _room(PuzzleRandom random, _Shape shape) {
    final inner = shape.inner, side = inner + 2;
    final (least, most) = shape.density;
    while (true) {
      final walls = [for (var cell = 0; cell < side * side; cell++) cell ~/ side == 0 || cell ~/ side == side - 1 || cell % side == 0 || cell % side == side - 1];
      // 切角：每个角三成的机会切掉一小块（边长不超过内部的三分之一），房间轮廓不总是方的。
      final notch = inner ~/ 3;
      for (var corner = 0; corner < 4; corner++) {
        if (!random.chance(.3)) continue;
        final rows = 1 + random.nextInt(notch), columns = 1 + random.nextInt(notch);
        for (var row = 0; row < rows; row++) {
          for (var column = 0; column < columns; column++) {
            final cellRow = corner < 2 ? 1 + row : side - 2 - row, cellColumn = corner.isEven ? 1 + column : side - 2 - column;
            walls[cellRow * side + cellColumn] = true;
          }
        }
      }
      final target = (inner * inner * (least + random.nextDouble() * (most - least))).round();
      var placed = walls.where((wall) => wall).length - (side * 4 - 4);
      for (var attempt = 0; attempt < 80 && placed < target; attempt++) {
        final piece = random.pick(_pieces);
        final row = 1 + random.nextInt(inner), column = 1 + random.nextInt(inner);
        final cells = <int>[];
        for (final (rowOffset, columnOffset) in piece) {
          final cellRow = row + rowOffset, cellColumn = column + columnOffset;
          if (cellRow > inner || cellColumn > inner || walls[cellRow * side + cellColumn]) break;
          cells.add(cellRow * side + cellColumn);
        }
        if (cells.length != piece.length) continue;
        for (final cell in cells) {
          walls[cell] = true;
        }
        if (_tidy(walls, side)) {
          placed += cells.length;
        } else {
          for (final cell in cells) {
            walls[cell] = false;
          }
        }
      }
      if (placed < target * .8 || !_tidy(walls, side) || _open(walls, side)) continue;
      return walls;
    }
  }

  // 墙块的形状（行、列的偏移）：单格、横竖两格与三格的条、四个朝向的 L。
  static const _pieces = [
    [(0, 0)],
    [(0, 0), (0, 1)],
    [(0, 0), (1, 0)],
    [(0, 0), (0, 1), (0, 2)],
    [(0, 0), (1, 0), (2, 0)],
    [(0, 0), (1, 0), (1, 1)],
    [(0, 0), (0, 1), (1, 0)],
    [(0, 1), (1, 0), (1, 1)],
    [(0, 0), (0, 1), (1, 1)],
  ];

  // 地面连通，且没有三面（或四面）是墙的死角格：死角里放不了箱子，只是白占地方。
  static bool _tidy(List<bool> walls, int side) {
    var first = -1, floor = 0;
    for (var cell = 0; cell < walls.length; cell++) {
      if (walls[cell]) continue;
      floor++;
      if (first < 0) first = cell;
      var open = 0;
      for (final offset in [-side, 1, side, -1]) {
        if (!walls[cell + offset]) open++;
      }
      if (open < 2) return false;
    }
    if (first < 0) return false;
    final seen = List.filled(walls.length, false)..[first] = true;
    final queue = [first];
    for (var head = 0; head < queue.length; head++) {
      for (final offset in [-side, 1, side, -1]) {
        final next = queue[head] + offset;
        if (walls[next] || seen[next]) continue;
        seen[next] = true;
        queue.add(next);
      }
    }
    return queue.length == floor;
  }

  // 有没有 3×3 全是地面的空地（太空旷：箱子怎么推都行，没意思）。
  static bool _open(List<bool> walls, int side) {
    for (var row = 1; row + 2 < side - 1; row++) {
      for (var column = 1; column + 2 < side - 1; column++) {
        var clear = true;
        for (var cell = 0; cell < 9 && clear; cell++) {
          clear = !walls[(row + cell ~/ 3) * side + column + cell % 3];
        }
        if (clear) return true;
      }
    }
    return false;
  }

  @override
  bool solved(BoxesPuzzle puzzle, List<int> answer) => answer.length <= boxesMaxMoves && boxesAllHome(puzzle, boxesReplay(puzzle, answer).boxes);

  @override
  int difficulty(BoxesPuzzle puzzle) {
    final solution = boxesSolve(puzzle);
    return solution == null ? 10 : boxesDifficulty(solution.pushes);
  }

  // 题面：宽高、墙（按行优先的 0、1 串）、目标点、箱子与玩家起点（格号）。
  @override
  Object encodePuzzle(BoxesPuzzle puzzle) => {
    'width': puzzle.width,
    'height': puzzle.height,
    'walls': puzzle.walls.map((wall) => wall ? '1' : '0').join(),
    'goals': [...puzzle.goals],
    'boxes': [...puzzle.boxes],
    'player': puzzle.player,
  };

  @override
  BoxesPuzzle decodePuzzle(Object? json) {
    final width = puzzleInt(json, 'width', min: boxesMinSide, max: boxesMaxSide), height = puzzleInt(json, 'height', min: boxesMinSide, max: boxesMaxSide);
    final cells = width * height;
    final text = (json as Map)['walls'];
    if (text is! String || text.length != cells || !RegExp(r'^[01]+$').hasMatch(text)) throw const FormatException('墙不合法');
    final walls = [for (final char in text.split('')) char == '1'];
    List<int> spots(String key) {
      final list = puzzleInts(json[key], maxLength: boxesMaxBoxes, min: 0, max: cells - 1);
      if (list.isEmpty || list.toSet().length != list.length || list.any((cell) => walls[cell])) throw FormatException('$key 不合法');
      return list..sort();
    }

    final goals = spots('goals'), boxes = spots('boxes');
    if (goals.length != boxes.length) throw const FormatException('箱子数与目标点数不一致');
    final player = puzzleInt(json, 'player', min: 0, max: cells - 1);
    if (walls[player] || boxes.contains(player)) throw const FormatException('玩家起点不合法');
    if (boxes.every(goals.contains)) throw const FormatException('题面已经解开');
    return BoxesPuzzle(width: width, height: height, walls: walls, goals: goals, boxes: boxes, player: player);
  }

  // 每步一个方向（0 上、1 右、2 下、3 左），最长 boxesMaxMoves 步。
  @override
  Object encodeAnswer(List<int> answer) => [...answer];

  @override
  List<int> decodeAnswer(Object? json) => puzzleInts(json, maxLength: boxesMaxMoves, min: 0, max: boxesDirections - 1);
}

// 难度分 1–10：按最少推数分段，段界对齐各档最少推数的区间（入门 4–8、简单 9–13、普通 14–19、困难 20–26、专家 27–40），
// 所以档与档的分数段不重叠：入门 1–2、简单 3、普通 4–5、困难 6–7、专家 8–10。箱子数已经随档定，推数又随箱子数涨，不另算。
int boxesDifficulty(int pushes) => switch (pushes) {
  <= 6 => 1,
  <= 8 => 2,
  <= 13 => 3,
  <= 16 => 4,
  <= 19 => 5,
  <= 23 => 6,
  <= 26 => 7,
  <= 31 => 8,
  <= 36 => 9,
  _ => 10,
};

// 一次推：箱子在 box、朝 direction 推一格。
typedef _Push = ({int box, int direction});

// 求解与倒推共用的棋盘：邻格表（-1 是墙或出界）、目标点、推送距离与死格，以及泛洪与拼键用的复用数组（搜索里每个状态都要用，不每次新建）。
// 局面的键：箱子格号升序、每个占 8 位拼成一个整数（最小的在最低位）。
class _Board {
  _Board(this.width, this.height, List<bool> walls, this.goals) : cells = width * height, count = goals.length {
    next = Int32List(cells * 4);
    _wall = Uint8List.fromList([for (final wall in walls) wall ? 1 : 0]);
    _goal = Uint8List(cells);
    for (final goal in goals) {
      _goal[goal] = 1;
    }
    for (var cell = 0; cell < cells; cell++) {
      for (var direction = 0; direction < 4; direction++) {
        final row = cell ~/ width + _rowStep[direction], column = cell % width + _columnStep[direction];
        final inside = row >= 0 && row < height && column >= 0 && column < width && !walls[row * width + column];
        next[cell * 4 + direction] = walls[cell] || !inside ? -1 : row * width + column;
      }
    }
    goalKey = _pack(goals);
    // 推送距离：从每个目标点倒着「拉」箱子（只看墙、不看别的箱子与玩家能不能走到），拉到某格的最少次数就是从那格推到这个目标点的最少次数；
    // 取到各目标点的最小值。拉不到的格是死格：箱子一进去就再也推不到任何目标点。
    distance = Int32List(cells)..fillRange(0, cells, _far);
    final queue = <int>[];
    for (final goal in goals) {
      distance[goal] = 0;
      queue.add(goal);
    }
    for (var head = 0; head < queue.length; head++) {
      final cell = queue[head];
      for (var direction = 0; direction < 4; direction++) {
        final stand = next[cell * 4 + direction];
        if (stand < 0 || next[stand * 4 + direction] < 0 || distance[stand] != _far) continue;
        distance[stand] = distance[cell] + 1;
        queue.add(stand);
      }
    }
  }

  static const _far = 1 << 20;
  final int width, height, cells, count;
  final List<int> goals;
  late final Int32List next;
  late final int goalKey;
  late final Int32List distance;
  late final Uint8List _wall, _goal;
  late final _occupied = Uint8List(cells);
  late final _mark = Int32List(cells);
  late final _queue = Int32List(cells);
  final _boxes = Int32List(boxesMaxBoxes), _sorted = Int32List(boxesMaxBoxes);
  var _stamp = 0, _filled = 0;

  static int _pack(List<int> boxes) {
    final sorted = [...boxes]..sort();
    var key = 0;
    for (final cell in sorted.reversed) {
      key = key << 8 | cell;
    }
    return key;
  }

  List<int> _unpack(int key) => [for (var index = 0; index < count; index++) key >> (index * 8) & 255];

  // 把局面的箱子解到 _boxes 并在 _occupied 上占位；用完 _unload 撤掉。
  void _load(int key) {
    for (var index = 0; index < count; index++) {
      final cell = key >> (index * 8) & 255;
      _boxes[index] = cell;
      _occupied[cell] = 1;
    }
  }

  void _unload() {
    for (var index = 0; index < count; index++) {
      _occupied[_boxes[index]] = 0;
    }
  }

  // _boxes 里的 from 换成 to 之后的键（插入排序保持升序，箱子最多 5 个）。
  int _movedKey(int from, int to) {
    for (var index = 0; index < count; index++) {
      final cell = _boxes[index];
      var at = index;
      final value = cell == from ? to : cell;
      while (at > 0 && _sorted[at - 1] > value) {
        _sorted[at] = _sorted[at - 1];
        at--;
      }
      _sorted[at] = value;
    }
    var key = 0;
    for (var index = count - 1; index >= 0; index--) {
      key = key << 8 | _sorted[index];
    }
    return key;
  }

  // 箱子放在 cell 上能不能被拉出来（有一个方向连着两格地面）：出题时目标点只挑这种格，不然那个箱子永远不用动。
  bool pullable(int cell) {
    for (var direction = 0; direction < 4; direction++) {
      final stand = next[cell * 4 + direction];
      if (stand >= 0 && next[stand * 4 + direction] >= 0) return true;
    }
    return false;
  }

  // 从 player 泛洪（箱子挡路），把能走到的格标上本次的戳，返回能走到的最小格号（区域的代表）；
  // 走到的格依次留在 _queue 的前 _filled 个里。
  int _fill(int player) {
    final stamp = ++_stamp;
    _mark[player] = stamp;
    _queue[0] = player;
    var tail = 1, least = player;
    for (var head = 0; head < tail; head++) {
      final base = _queue[head] * 4;
      for (var direction = 0; direction < 4; direction++) {
        final neighbor = next[base + direction];
        if (neighbor < 0 || _occupied[neighbor] == 1 || _mark[neighbor] == stamp) continue;
        _mark[neighbor] = stamp;
        _queue[tail++] = neighbor;
        if (neighbor < least) least = neighbor;
      }
    }
    _filled = tail;
    return least;
  }

  // 2×2 死块：箱子刚推到 to，它所在的四个 2×2 里有一个全是墙或箱子、且其中有箱子不在目标点上，这些箱子谁也推不动了。
  bool _frozen(int to) {
    final row = to ~/ width, column = to % width;
    bool solid(int cellRow, int cellColumn) =>
        cellRow < 0 || cellRow >= height || cellColumn < 0 || cellColumn >= width || _wall[cellRow * width + cellColumn] == 1 || _occupied[cellRow * width + cellColumn] == 1;
    bool stuck(int cellRow, int cellColumn) =>
        cellRow >= 0 && cellRow < height && cellColumn >= 0 && cellColumn < width && _occupied[cellRow * width + cellColumn] == 1 && _goal[cellRow * width + cellColumn] == 0;
    for (final rowStep in const [-1, 1]) {
      for (final columnStep in const [-1, 1]) {
        if (!solid(row + rowStep, column) || !solid(row, column + columnStep) || !solid(row + rowStep, column + columnStep)) continue;
        if (stuck(row, column) || stuck(row + rowStep, column) || stuck(row, column + columnStep) || stuck(row + rowStep, column + columnStep)) return true;
      }
    }
    return false;
  }

  int _estimate(int key) {
    var sum = 0;
    for (var index = 0; index < count; index++) {
      sum += distance[key >> (index * 8) & 255];
    }
    return sum;
  }

  // 正向 A*：返回最少推数的一串推法与展开数，超上限或解不开返回 null。
  // 开放表按估价分桶（估价是小整数），同一桶后进先出（更深的先试，找到终局更快，不影响最少推数）。
  ({List<_Push> pushes, int expanded})? forward(List<int> startBoxes, int startPlayer, int limit) {
    final startKey = _pack(startBoxes);
    if (_estimate(startKey) >= _far) return null;
    final keys = <int>[startKey], players = <int>[startPlayer], costs = <int>[0], parents = <int>[-1], pushBox = <int>[-1], pushDirection = <int>[-1];
    final buckets = <List<int>>[];
    void enqueue(int state, int estimate) {
      while (buckets.length <= estimate) {
        buckets.add(<int>[]);
      }
      buckets[estimate].add(state);
    }

    // 生成过的「箱子 + 玩家站的格」与它最小的推数：更省的路再来才重新入队。
    final best = HashMap<int, int>()..[startKey << 8 | startPlayer] = 0;
    final closed = HashSet<int>();
    enqueue(0, _estimate(startKey));
    var expanded = 0;
    for (var bucket = 0; bucket < buckets.length; bucket++) {
      final list = buckets[bucket];
      while (list.isNotEmpty) {
        final state = list.removeLast();
        final key = keys[state];
        _load(key);
        final region = _fill(players[state]);
        if (!closed.add(key << 8 | region)) {
          _unload();
          continue;
        }
        if (key == goalKey) {
          _unload();
          final pushes = <_Push>[];
          for (var at = state; parents[at] >= 0; at = parents[at]) {
            pushes.add((box: pushBox[at], direction: pushDirection[at]));
          }
          return (pushes: pushes.reversed.toList(), expanded: expanded);
        }
        if (++expanded > limit) {
          _unload();
          return null;
        }
        final stamp = _stamp, cost = costs[state] + 1;
        for (var index = 0; index < count; index++) {
          final box = _boxes[index];
          for (var direction = 0; direction < 4; direction++) {
            final to = next[box * 4 + direction], stand = next[box * 4 + (direction + 2) % 4];
            if (to < 0 || stand < 0 || _mark[stand] != stamp || _occupied[to] == 1 || distance[to] == _far) continue;
            _occupied[box] = 0;
            _occupied[to] = 1;
            final frozen = _frozen(to);
            _occupied[to] = 0;
            _occupied[box] = 1;
            if (frozen) continue;
            final child = _movedKey(box, to);
            final raw = child << 8 | box;
            final known = best[raw];
            if (known != null && known <= cost) continue;
            best[raw] = cost;
            keys.add(child);
            players.add(box);
            costs.add(cost);
            parents.add(state);
            pushBox.add(box);
            pushDirection.add(direction);
            enqueue(keys.length - 1, cost + _estimate(child));
          }
        }
        _unload();
      }
    }
    return null;
  }

  // 倒推：从箱子全在目标点上（玩家在每一块区域各算一个起点）出发，广度优先地拉箱子，最多收 limit 个局面；
  // 在层数落在 [low, high] 的局面里挑最深一层，随机取一个合格的。挑不出返回 null。
  ({List<int> boxes, int player, int depth, List<_Push> pushes})? reverse(PuzzleRandom random, int low, int high, int limit) {
    final keys = <int>[], players = <int>[], depths = <int>[], parents = <int>[], pullBox = <int>[], pullDirection = <int>[];
    _load(goalKey);
    final covered = Uint8List(cells);
    for (var cell = 0; cell < cells; cell++) {
      if (_wall[cell] == 1 || _occupied[cell] == 1 || covered[cell] == 1) continue;
      _fill(cell);
      for (var other = 0; other < cells; other++) {
        if (_mark[other] == _stamp) covered[other] = 1;
      }
      keys.add(goalKey);
      players.add(cell);
      depths.add(0);
      parents.add(-1);
      pullBox.add(-1);
      pullDirection.add(-1);
    }
    _unload();
    // 收下的局面（在队列里的下标）：每个「箱子 + 区域」只收第一次取到的，那时的层数就是最少推数。
    // 同一组箱子收下过的区域按位记下（每 64 格一个整数）：玩家落在记过的区域里就是重复的局面，不用泛洪就能扔掉，
    // 生成子局面时也先查一遍，重复的不进队列（不查的话队列里约四分之三是重复，倒推慢三四倍）。
    final words = (cells + 63) >> 6;
    final regions = HashMap<int, List<int>>();
    bool known(int key, int player) {
      final list = regions[key];
      if (list == null) return false;
      final word = player >> 6, bit = 1 << (player & 63);
      for (var start = 0; start < list.length; start += words) {
        if (list[start + word] & bit != 0) return true;
      }
      return false;
    }

    final accepted = <int>[];
    for (var head = 0; head < keys.length && accepted.length < limit; head++) {
      if (depths[head] > high) break;
      final key = keys[head];
      if (known(key, players[head])) continue;
      _load(key);
      _fill(players[head]);
      accepted.add(head);
      final stamp = _stamp, depth = depths[head] + 1;
      // 泛洪的队列里正好是这块区域的格。
      final list = regions[key] ??= <int>[];
      final start = list.length;
      for (var word = 0; word < words; word++) {
        list.add(0);
      }
      for (var index = 0; index < _filled; index++) {
        final cell = _queue[index];
        list[start + (cell >> 6)] |= 1 << (cell & 63);
      }
      for (var index = 0; index < count; index++) {
        final box = _boxes[index];
        for (var direction = 0; direction < 4; direction++) {
          // 玩家站在箱子的 direction 一侧，朝 direction 再退一格，把箱子拉到自己原来站的格。
          final stand = next[box * 4 + direction];
          if (stand < 0 || _mark[stand] != stamp) continue;
          final back = next[stand * 4 + direction];
          if (back < 0 || _occupied[back] == 1) continue;
          final child = _movedKey(box, stand);
          if (known(child, back)) continue;
          keys.add(child);
          players.add(back);
          depths.add(depth);
          parents.add(head);
          pullBox.add(box);
          pullDirection.add(direction);
        }
      }
      _unload();
    }
    // 从最深的一层往浅里找，每层打乱后逐个看合不合格。
    final levels = <int, List<int>>{};
    for (final head in accepted) {
      final depth = depths[head];
      if (depth >= low) (levels[depth] ??= []).add(head);
    }
    final order = levels.keys.toList()..sort();
    for (final depth in order.reversed) {
      final candidates = levels[depth]!;
      random.shuffle(candidates);
      for (final head in candidates.take(12)) {
        // 顺着倒推链正着推回去：倒推那一步把箱子从 pullBox 拉到它的 pullDirection 一侧，正着推是从那一侧推回 pullBox，方向相反。
        final pushes = <_Push>[
          for (var at = head; parents[at] >= 0; at = parents[at]) (box: next[pullBox[at] * 4 + pullDirection[at]], direction: (pullDirection[at] + 2) % 4),
        ];
        final boxes = _unpack(keys[head]);
        if (!_lively(boxes, pushes)) continue;
        _load(keys[head]);
        _fill(players[head]);
        final region = [for (var index = 0; index < _filled; index++) _queue[index]]..sort();
        _unload();
        return (boxes: boxes..sort(), player: random.pick(region), depth: depth, pushes: pushes);
      }
    }
    return null;
  }

  // 合格的开局：每个箱子都至少挪一次，且「推的段数」（同一个箱子朝同一方向连着推算一段）比箱子数多，不是每个箱子各自一推到底就完。
  bool _lively(List<int> start, List<_Push> pushes) {
    final boxes = [...start];
    final moved = List.filled(count, false);
    var segments = 0, lastBox = -1, lastDirection = -1;
    for (final push in pushes) {
      final index = boxes.indexOf(push.box);
      boxes[index] = next[push.box * 4 + push.direction];
      moved[index] = true;
      if (index != lastBox || push.direction != lastDirection) segments++;
      lastBox = index;
      lastDirection = push.direction;
    }
    return !moved.contains(false) && segments > count;
  }

  // 把一串推法展开成每步的方向：每次推之前，广度优先走最短的路到箱子背后那一格，再推。
  List<int> expand(List<int> startBoxes, int startPlayer, List<_Push> pushes) {
    final moves = <int>[];
    final boxes = [...startBoxes];
    var player = startPlayer;
    final from = Int32List(cells), via = Int32List(cells);
    for (final push in pushes) {
      final stand = next[push.box * 4 + (push.direction + 2) % 4];
      for (final cell in boxes) {
        _occupied[cell] = 1;
      }
      final stamp = ++_stamp;
      _mark[player] = stamp;
      _queue[0] = player;
      var tail = 1;
      for (var head = 0; head < tail && _mark[stand] != stamp; head++) {
        final cell = _queue[head];
        for (var direction = 0; direction < 4; direction++) {
          final neighbor = next[cell * 4 + direction];
          if (neighbor < 0 || _occupied[neighbor] == 1 || _mark[neighbor] == stamp) continue;
          _mark[neighbor] = stamp;
          from[neighbor] = cell;
          via[neighbor] = direction;
          _queue[tail++] = neighbor;
        }
      }
      for (final cell in boxes) {
        _occupied[cell] = 0;
      }
      final path = <int>[];
      for (var cell = stand; cell != player; cell = from[cell]) {
        path.add(via[cell]);
      }
      moves
        ..addAll(path.reversed)
        ..add(push.direction);
      boxes[boxes.indexOf(push.box)] = next[push.box * 4 + push.direction];
      player = push.box;
    }
    return moves;
  }
}
