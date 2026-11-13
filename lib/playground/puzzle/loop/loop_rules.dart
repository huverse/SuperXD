import 'dart:typed_data';

import 'package:superxd/playground/puzzle_rules.dart';

// 数回（Slitherlink）：在点阵上画一条闭合的回路，格子里的数字是这一格四条边里有几条在回路上；回路不分叉、不交叉、只有一条，没有数字的格不限。
// 出的题保证唯一解（求解器数到第 2 个解就停，唯一才出）。
class LoopPuzzle {
  const LoopPuzzle({required this.width, required this.height, required this.clues});
  final int width;
  final int height;
  // clues[行 × width + 列] = 这一格的数字 0–3，没有数字是 -1。
  final List<int> clues;
}

const loopMinSide = 2;
// 外部输入的上限：专家档 10 见方留有余地，再大的坏题求解器可能要算很久。
const loopMaxSide = 12;

// 点阵的几何（题面、答案与对局页共用，下标规则发出后不改）：width × height 个格，(width + 1) × (height + 1) 个点，点的下标是「行 × (width + 1) + 列」。
// 边先排横边再排竖边：第 r 行点（0 到 height）上从左数第 c 段横边是 r × width + c；
// 第 r 行格（0 到 height - 1）里从左数第 c 条竖边（0 到 width）是 (height + 1) × width + r × (width + 1) + c。
// 一格的四条边按上、右、下、左排（0 到 3），四个角按左上、右上、右下、左下排（0 到 3），第 k 个角的两条边是第 (k + 3) % 4 与第 k 条边。
class LoopGrid {
  LoopGrid._(this.width, this.height, this.cellEdges, this.edgeEnds, this.edgeCells, this.vertexEdges, this.vertexCells);

  // 同一个尺寸只算一次（边长不超过 loopMaxSide，最多 loopMaxSide² 份）。
  factory LoopGrid.of(int width, int height) => _grids.putIfAbsent(width * 100 + height, () => _build(width, height));
  static final _grids = <int, LoopGrid>{};

  final int width;
  final int height;
  // 每格四条边，按上、右、下、左排。
  final Int32List cellEdges;
  // 每条边两头的点：横边先左后右，竖边先上后下。
  final Int32List edgeEnds;
  // 每条边两边的格：横边先上后下，竖边先左后右；棋盘外是 -1。
  final Int32List edgeCells;
  // 每个点四个方向的边，按上、右、下、左排；没有是 -1。
  final Int32List vertexEdges;
  // 每个点挨着的四格，按「这个点是那一格的第几个角」排：0 是右下那格、1 左下、2 左上、3 右上；棋盘外是 -1。
  final Int32List vertexCells;

  int get cellCount => width * height;
  int get horizontalCount => (height + 1) * width;
  int get edgeCount => horizontalCount + height * (width + 1);
  int get vertexCount => (width + 1) * (height + 1);

  int horizontal(int row, int column) => row * width + column;
  int vertical(int row, int column) => horizontalCount + row * (width + 1) + column;
  bool isHorizontal(int edge) => edge < horizontalCount;

  // 一格第 corner 个角上的点。
  int cornerVertex(int cell, int corner) {
    final top = cell ~/ width * (width + 1) + cell % width;
    return switch (corner) { 0 => top, 1 => top + 1, 2 => top + width + 2, _ => top + width + 1 };
  }

  // 两个相邻的点之间那条边；不相邻是 -1。
  int edgeBetween(int from, int to) {
    final (low, high) = from < to ? (from, to) : (to, from);
    if (high - low == 1 && low % (width + 1) != width) return vertexEdges[low * 4 + 1];
    if (high - low == width + 1) return vertexEdges[low * 4 + 2];
    return -1;
  }

  static LoopGrid _build(int width, int height) {
    final stride = width + 1, horizontals = (height + 1) * width;
    final edges = horizontals + height * stride, vertices = stride * (height + 1);
    final cellEdges = Int32List(width * height * 4);
    for (var row = 0; row < height; row++) {
      for (var column = 0; column < width; column++) {
        final base = (row * width + column) * 4;
        cellEdges[base] = row * width + column;
        cellEdges[base + 1] = horizontals + row * stride + column + 1;
        cellEdges[base + 2] = (row + 1) * width + column;
        cellEdges[base + 3] = horizontals + row * stride + column;
      }
    }
    final edgeEnds = Int32List(edges * 2), edgeCells = Int32List(edges * 2)..fillRange(0, edges * 2, -1);
    final vertexEdges = Int32List(vertices * 4)..fillRange(0, vertices * 4, -1);
    final vertexCells = Int32List(vertices * 4)..fillRange(0, vertices * 4, -1);
    for (var row = 0; row <= height; row++) {
      for (var column = 0; column < width; column++) {
        final edge = row * width + column, left = row * stride + column;
        edgeEnds[edge * 2] = left;
        edgeEnds[edge * 2 + 1] = left + 1;
        if (row > 0) edgeCells[edge * 2] = (row - 1) * width + column;
        if (row < height) edgeCells[edge * 2 + 1] = row * width + column;
        vertexEdges[left * 4 + 1] = edge;
        vertexEdges[(left + 1) * 4 + 3] = edge;
      }
    }
    for (var row = 0; row < height; row++) {
      for (var column = 0; column <= width; column++) {
        final edge = horizontals + row * stride + column, top = row * stride + column;
        edgeEnds[edge * 2] = top;
        edgeEnds[edge * 2 + 1] = top + stride;
        if (column > 0) edgeCells[edge * 2] = row * width + column - 1;
        if (column < width) edgeCells[edge * 2 + 1] = row * width + column;
        vertexEdges[top * 4 + 2] = edge;
        vertexEdges[(top + stride) * 4] = edge;
      }
    }
    for (var row = 0; row <= height; row++) {
      for (var column = 0; column <= width; column++) {
        final base = (row * stride + column) * 4;
        if (row < height && column < width) vertexCells[base] = row * width + column;
        if (row < height && column > 0) vertexCells[base + 1] = row * width + column - 1;
        if (row > 0 && column > 0) vertexCells[base + 2] = (row - 1) * width + column - 1;
        if (row > 0 && column < width) vertexCells[base + 3] = (row - 1) * width + column;
      }
    }
    return LoopGrid._(width, height, cellEdges, edgeEnds, edgeCells, vertexEdges, vertexCells);
  }
}

// 求解的结果：解的个数（数到 limit 就停）、第一个解（每条边是不是线）、开头只靠推理走了几轮、试探过几次（分支数）。
typedef LoopSolveResult = ({int count, List<bool>? first, int rounds, int branches});

// 求解器：边有三态（未定、线、叉），先反复推理到推不动，再挑一条边试「是线」与「是叉」两支，数到 limit 个解就停。推理有这几条：
// 1. 格子的数字：线已够数，其余是叉；未定的全算上才够数，全是线。
// 2. 每个点连 0 或 2 条线：已有两条其余是叉；一条线只剩一条未定边就接上；没有线只剩一条未定边就是叉。
// 3. 不能提前闭合成小圈：一段线两头相邻、外面还有别的线，中间那条是叉；接上就闭合的那一下，圈外还有线就是矛盾，圈正好是全部的线就把其余边都定成叉。
// 4. 格角：每格每个角的两条边记着可能有几条线（0、1、2 的集合）。数字格对角两个角的线数加起来等于数字；一个点上一角的线数加上其余边的线数是 0 或 2；
//    再按集合定边。角落的 3 两边都是线、1 两边都是叉这类常见手筋都从这里推出来。
// 5. 圈里圈外：边是线当且仅当两边的格一里一外，已知同侧、异侧的关系用带奇偶的并查集记，两格进了同一组，中间那条边就定了。
// 6. 全部的线要能沿着不是叉的边连成一片，连不上就是矛盾。
// 试探挑线头（度为 1 的点）里未定边最少、所在那段线最短的那个，没有线头挑还差线最多的数字格；挑法固定，唯一解的题数满两个之前
// 会把整棵树走完，所以分支数是这道题确定的值，进难度分。rounds 是开头那次推理走了几轮（一轮 = 上一轮改过的边牵涉的格与点各查一遍）。
LoopSolveResult loopSolve(LoopPuzzle puzzle, {int limit = 2}) => _LoopSolver(puzzle.width, puzzle.height, _allowedOf(puzzle.clues)).solve(limit);

// 只推理、不试探：从题面加上已知的边（given 是边的下标到「是不是线」）推到推不动，返回每条边的结论（true 线、false 叉、null 未定），
// 和已知矛盾返回 null。用来逐条核对推理规则（测试），以后做提示也用得上。
List<bool?>? loopDeduce(LoopPuzzle puzzle, {Map<int, bool> given = const {}}) => _LoopSolver(puzzle.width, puzzle.height, _allowedOf(puzzle.clues)).deduce(given);

// 每格允许的线数集合（第 n 位是「n 条线」，0 到 4）：有数字的只允许这个数，没数字的不限。
const _anyClue = 31;
Uint8List _allowedOf(List<int> clues) => Uint8List.fromList([for (final clue in clues) clue < 0 ? _anyClue : 1 << clue]);

const _unknown = 0, _line = 1, _cross = 2;
// 格角可能的线数集合：第 n 位是「有 n 条线」，全集是 0b111。
const _anyCount = 7;

// 搜索状态：每条边的三态、每个点连了几条线、每个格角可能的线数；线段的两头互相记着对方（partner）与这一段的边数（length），
// 只在度为 1 的点上有效；圈里圈外的并查集（parent，side 是相对父节点在不在异侧，棋盘外是最后一个节点）。
class _LoopState {
  _LoopState(LoopGrid grid)
    : edges = Uint8List(grid.edgeCount),
      degree = Uint8List(grid.vertexCount),
      corners = Uint8List(grid.cellCount * 4)..fillRange(0, grid.cellCount * 4, _anyCount),
      partner = Int32List(grid.vertexCount),
      length = Int32List(grid.vertexCount),
      parent = Int32List.fromList([for (var node = 0; node <= grid.cellCount; node++) node]),
      side = Uint8List(grid.cellCount + 1),
      unknown = grid.edgeCount;
  _LoopState._(this.edges, this.degree, this.corners, this.partner, this.length, this.parent, this.side, this.unknown, this.lines, this.closed);

  final Uint8List edges;
  final Uint8List degree;
  final Uint8List corners;
  final Int32List partner;
  final Int32List length;
  final Int32List parent;
  final Uint8List side;
  int unknown;
  int lines = 0;
  bool closed = false;

  _LoopState copy() => _LoopState._(
    Uint8List.fromList(edges),
    Uint8List.fromList(degree),
    Uint8List.fromList(corners),
    Int32List.fromList(partner),
    Int32List.fromList(length),
    Int32List.fromList(parent),
    Uint8List.fromList(side),
    unknown,
    lines,
    closed,
  );

  // 所在组的根，_flip 记下这一格相对根在不在异侧（1 是异侧）；顺手压缩路径。
  int find(int node) {
    var root = node, flip = 0;
    while (parent[root] != root) {
      flip ^= side[root];
      root = parent[root];
    }
    var current = node, rest = flip;
    while (current != root && parent[current] != root) {
      final next = parent[current], nextRest = rest ^ side[current];
      parent[current] = root;
      side[current] = rest;
      current = next;
      rest = nextRest;
    }
    _flip = flip;
    return root;
  }

  int _flip = 0;

  // 记下两格同侧（apart 为 0）或异侧（1）；和已知矛盾返回 false。
  bool relate(int first, int second, int apart) {
    final firstRoot = find(first), firstFlip = _flip;
    final secondRoot = find(second), secondFlip = _flip;
    if (firstRoot == secondRoot) return firstFlip ^ secondFlip == apart;
    parent[firstRoot] = secondRoot;
    side[firstRoot] = firstFlip ^ secondFlip ^ apart;
    return true;
  }

  // 两格的关系：同组时 0 是同侧、1 是异侧，不同组是 -1。
  int relation(int first, int second) {
    final firstRoot = find(first), firstFlip = _flip;
    final secondRoot = find(second), secondFlip = _flip;
    return firstRoot == secondRoot ? firstFlip ^ secondFlip : -1;
  }
}

// 已知 lines 条线、unknown 条未定时可能的线数集合。
int _countRange(int lines, int unknown) => ((1 << (unknown + 1)) - 1) << lines;

class _LoopSolver {
  _LoopSolver(int width, int height, this.allowed, {this.guide, this.budget = 1 << 30})
    : grid = LoopGrid.of(width, height),
      _queued = Uint8List(width * height + (width + 1) * (height + 1)),
      _seen = Int32List((width + 1) * (height + 1)),
      _stack = Int32List((width + 1) * (height + 1));

  final LoopGrid grid;
  // 每格允许的线数集合（见 _allowedOf）；出题时拿掉一个数字前，把那一格设成「除了原来那个数都行」，找得到解就说明拿掉后不唯一。
  final Uint8List allowed;
  // 参考解（每条边是不是线），只决定试探时先试哪一支，不影响结果。
  final List<bool>? guide;
  // 最多试探几次；超了就停下，记 overBudget。
  final int budget;
  var overBudget = false;
  // 待查的格（下标 0 到格数 - 1）与点（格数 + 点的下标），按轮分批：这一轮查出来要再查的放进下一轮。
  var _wave = <int>[];
  var _next = <int>[];
  final Uint8List _queued;
  var _rounds = 0;
  // 连通检查用的走过标记（按次数记，不用每次清零）与栈。
  final Int32List _seen;
  final Int32List _stack;
  var _visit = 0;

  LoopSolveResult solve(int limit) {
    final state = _LoopState(grid);
    for (var item = 0; item < _queued.length; item++) {
      _enqueue(item);
    }
    if (!_propagate(state)) return (count: 0, first: null, rounds: _rounds, branches: 0);
    final rounds = _rounds;
    var count = 0, branches = 0;
    List<bool>? first;
    void search(_LoopState state) {
      if (state.unknown == 0) {
        // 全部定下且没有矛盾：每个点 0 或 2 条线，闭合过就是一个圈（闭合时已核对圈外没有线），没闭合过就是一条线都没有。
        if (state.closed) {
          count++;
          first ??= [for (final value in state.edges) value == _line];
        }
        return;
      }
      if (branches >= budget) {
        overBudget = true;
        return;
      }
      final edge = _choose(state);
      branches++;
      // 先试哪一支：给了参考解就先跟着参考解走（找别的解时，别的解多半只在一小块和参考解不同），没给先试线。
      final guide = this.guide;
      final tryFirst = guide == null || guide[edge] ? _line : _cross;
      final child = state.copy();
      if (_assign(child, edge, tryFirst) && _propagate(child)) search(child);
      if (count >= limit || overBudget) return;
      // 第二支直接在本层的状态上改，省一次复制。
      if (_assign(state, edge, _line + _cross - tryFirst) && _propagate(state)) search(state);
    }

    search(state);
    return (count: count, first: first, rounds: rounds, branches: branches);
  }

  List<bool?>? deduce(Map<int, bool> given) {
    final state = _LoopState(grid);
    for (var item = 0; item < _queued.length; item++) {
      _enqueue(item);
    }
    for (final MapEntry(key: edge, value: line) in given.entries) {
      if (!_assign(state, edge, line ? _line : _cross)) {
        _abandon();
        return null;
      }
    }
    if (!_propagate(state)) return null;
    return [for (final value in state.edges) value == _unknown ? null : value == _line];
  }

  void _enqueue(int item) {
    if (_queued[item] != 0) return;
    _queued[item] = 1;
    _next.add(item);
  }

  // 推理到推不动，矛盾返回 false（并清空待查表，留给下一次用）。先逐格逐点推到不再变化，再做全盘的几件事，推出新的就回头接着推。
  bool _propagate(_LoopState state) {
    final cells = grid.cellCount;
    while (true) {
      while (_next.isNotEmpty) {
        _rounds++;
        final wave = _next;
        _next = _wave;
        _wave = wave;
        for (var index = 0; index < wave.length; index++) {
          final item = wave[index];
          final consistent = item < cells ? _checkCell(state, item) : _checkVertex(state, item - cells);
          _queued[item] = 0;
          if (!consistent) {
            for (final rest in wave.skip(index + 1)) {
              _queued[rest] = 0;
            }
            wave.clear();
            return _abandon();
          }
        }
        wave.clear();
      }
      final swept = _sweep(state);
      if (swept == null) return _abandon();
      if (!swept) return true;
    }
  }

  bool _abandon() {
    for (final item in _next) {
      _queued[item] = 0;
    }
    _next.clear();
    return false;
  }

  // 全盘的几件事，返回推出了新的没有，矛盾返回 null：闭合成圈以后剩下的边都是叉（数字格不够数时下一轮查出矛盾）；
  // 禁止提前闭合的小圈；两边的格已知同侧的未定边是叉、异侧的是线；最后查全部的线还连不连得成一片。
  bool? _sweep(_LoopState state) {
    var changed = false;
    if (state.closed) {
      for (var edge = 0; edge < grid.edgeCount && state.unknown > 0; edge++) {
        if (state.edges[edge] != _unknown) continue;
        if (!_assign(state, edge, _cross)) return null;
        changed = true;
      }
      return changed;
    }
    for (var vertex = 0; vertex < grid.vertexCount; vertex++) {
      if (state.degree[vertex] != 1) continue;
      final other = state.partner[vertex];
      if (other < vertex || state.lines <= state.length[vertex]) continue;
      final edge = grid.edgeBetween(vertex, other);
      if (edge < 0 || state.edges[edge] != _unknown) continue;
      if (!_assign(state, edge, _cross)) return null;
      changed = true;
    }
    if (changed) return true;
    final outside = grid.cellCount;
    for (var edge = 0; edge < grid.edgeCount; edge++) {
      if (state.edges[edge] != _unknown) continue;
      final first = grid.edgeCells[edge * 2], second = grid.edgeCells[edge * 2 + 1];
      final relation = state.relation(first < 0 ? outside : first, second < 0 ? outside : second);
      if (relation < 0) continue;
      if (!_assign(state, edge, relation == 1 ? _line : _cross)) return null;
      changed = true;
    }
    if (changed) return true;
    return _connected(state) ? false : null;
  }

  // 全部的线能否沿着不是叉的边连成一片（最后只有一个圈）。
  bool _connected(_LoopState state) {
    if (state.closed || state.lines == 0) return true;
    var start = -1, touched = 0;
    for (var vertex = 0; vertex < grid.vertexCount; vertex++) {
      if (state.degree[vertex] == 0) continue;
      touched++;
      start = vertex;
    }
    final visit = ++_visit;
    _seen[start] = visit;
    _stack[0] = start;
    var size = 1, reached = 0;
    while (size > 0) {
      final vertex = _stack[--size];
      if (state.degree[vertex] > 0) reached++;
      for (var side = 0; side < 4; side++) {
        final edge = grid.vertexEdges[vertex * 4 + side];
        if (edge < 0 || state.edges[edge] == _cross) continue;
        final other = grid.edgeEnds[edge * 2] == vertex ? grid.edgeEnds[edge * 2 + 1] : grid.edgeEnds[edge * 2];
        if (_seen[other] == visit) continue;
        _seen[other] = visit;
        _stack[size++] = other;
      }
    }
    return reached == touched;
  }

  // 定下一条边，把它两边的格与两头的点放进下一轮；和已知矛盾返回 false。
  bool _assign(_LoopState state, int edge, int value) {
    final current = state.edges[edge];
    if (current != _unknown) return current == value;
    final a = grid.edgeEnds[edge * 2], b = grid.edgeEnds[edge * 2 + 1];
    if (value == _line) {
      final degreeA = state.degree[a], degreeB = state.degree[b];
      if (state.closed || degreeA >= 2 || degreeB >= 2) return false;
      final endA = degreeA == 0 ? a : state.partner[a], endB = degreeB == 0 ? b : state.partner[b];
      final lengthA = degreeA == 0 ? 0 : state.length[a], lengthB = degreeB == 0 ? 0 : state.length[b];
      state.degree[a] = degreeA + 1;
      state.degree[b] = degreeB + 1;
      state.lines++;
      if (endA == b) {
        // 接上就闭合成圈：它必须已经是全部的线，否则圈外的线永远连不进来。
        if (state.lines != lengthA + 1) return false;
        state.closed = true;
      } else {
        state.partner[endA] = endB;
        state.partner[endB] = endA;
        state.length[endA] = state.length[endB] = lengthA + lengthB + 1;
      }
    }
    state.edges[edge] = value;
    state.unknown--;
    final first = grid.edgeCells[edge * 2], second = grid.edgeCells[edge * 2 + 1], outside = grid.cellCount;
    if (!state.relate(first < 0 ? outside : first, second < 0 ? outside : second, value == _line ? 1 : 0)) return false;
    if (first >= 0) _enqueue(first);
    if (second >= 0) _enqueue(second);
    _enqueue(outside + a);
    _enqueue(outside + b);
    return true;
  }

  // 一格：数字格先按线数定边（还可能的线数只剩眼下的线数，未定的都是叉；只剩全算上的数，未定的都是线），再让对角两个角的线数
  // 加起来是允许的数；最后四个角都按可能的线数定边。
  bool _checkCell(_LoopState state, int cell) {
    final mask = allowed[cell], base = cell * 4;
    if (mask != _anyClue) {
      var lines = 0, unknown = 0;
      for (var side = 0; side < 4; side++) {
        final value = state.edges[grid.cellEdges[base + side]];
        if (value == _line) {
          lines++;
        } else if (value == _unknown) {
          unknown++;
        }
      }
      final possible = mask & _countRange(lines, unknown);
      if (possible == 0) return false;
      final fill = unknown == 0 ? _unknown : possible == 1 << lines ? _cross : possible == 1 << (lines + unknown) ? _line : _unknown;
      if (fill != _unknown) {
        for (var side = 0; side < 4; side++) {
          final edge = grid.cellEdges[base + side];
          if (state.edges[edge] == _unknown && !_assign(state, edge, fill)) return false;
        }
      }
      for (var corner = 0; corner < 4; corner++) {
        if (!_narrowCorner(state, cell, corner, _rest(mask, _cornerCounts(state, cell, (corner + 2) % 4)))) return false;
      }
    }
    for (var corner = 0; corner < 4; corner++) {
      if (!_narrowCorner(state, cell, corner, _anyCount)) return false;
    }
    return true;
  }

  // 一个点：连 0 或 2 条线；挨着的每一格的那个角，线数加上这个点其余边（对面那格的角）的线数是 0 或 2。
  bool _checkVertex(_LoopState state, int vertex) {
    final base = vertex * 4;
    var lines = 0, unknown = 0;
    for (var side = 0; side < 4; side++) {
      final edge = grid.vertexEdges[base + side];
      if (edge < 0) continue;
      final value = state.edges[edge];
      if (value == _line) {
        lines++;
      } else if (value == _unknown) {
        unknown++;
      }
    }
    if (lines > 2 || unknown == 0 && lines == 1) return false;
    final fill = unknown == 0 ? _unknown : lines == 2 ? _cross : unknown == 1 ? (lines == 1 ? _line : _cross) : _unknown;
    if (fill != _unknown) {
      for (var side = 0; side < 4; side++) {
        final edge = grid.vertexEdges[base + side];
        if (edge >= 0 && state.edges[edge] == _unknown && !_assign(state, edge, fill)) return false;
      }
    }
    for (var slot = 0; slot < 4; slot++) {
      final cell = grid.vertexCells[base + slot];
      if (cell < 0) continue;
      // 这一角占这个点的两条边，其余是第 slot 与第 (slot + 3) % 4 个方向的边，也正是对面那格的角。
      final near = grid.vertexEdges[base + slot], far = grid.vertexEdges[base + (slot + 3) % 4];
      final nearValue = near < 0 ? _cross : state.edges[near], farValue = far < 0 ? _cross : state.edges[far];
      var rest = _countRange((nearValue == _line ? 1 : 0) + (farValue == _line ? 1 : 0), (nearValue == _unknown ? 1 : 0) + (farValue == _unknown ? 1 : 0));
      final facing = grid.vertexCells[base + (slot + 2) % 4];
      if (facing >= 0) rest &= state.corners[facing * 4 + (slot + 2) % 4];
      // 其余有 0 条：这一角 0 或 2 条；其余 1 条：这一角 1 条；其余 2 条：这一角 0 条。
      final allowed = (rest & 1 != 0 ? 5 : 0) | (rest & 2 != 0 ? 2 : 0) | (rest & 4 != 0 ? 1 : 0);
      if (!_narrowCorner(state, cell, slot, allowed)) return false;
    }
    return true;
  }

  // 一个角眼下可能的线数：记下的集合再按两条边的现状收窄。
  int _cornerCounts(_LoopState state, int cell, int corner) {
    final first = state.edges[grid.cellEdges[cell * 4 + (corner + 3) % 4]], second = state.edges[grid.cellEdges[cell * 4 + corner]];
    final lines = (first == _line ? 1 : 0) + (second == _line ? 1 : 0), unknown = (first == _unknown ? 1 : 0) + (second == _unknown ? 1 : 0);
    return state.corners[cell * 4 + corner] & _countRange(lines, unknown);
  }

  // 这一格允许 mask 里的线数、对角那个角可能有 counts 条线时，这个角可能的线数。
  static int _rest(int mask, int counts) {
    var rest = 0;
    for (var total = 0; total <= 4; total++) {
      if (mask & (1 << total) == 0) continue;
      for (var count = 0; count <= 2; count++) {
        if (counts & (1 << count) != 0 && total - count >= 0 && total - count <= 2) rest |= 1 << (total - count);
      }
    }
    return rest;
  }

  // 把一个角可能的线数收窄到 allowed，再按集合定它的两条边（某条边是线、是叉都凑不出集合里的数就矛盾，只有一种凑得出就定下）。
  bool _narrowCorner(_LoopState state, int cell, int corner, int allowed) {
    final index = cell * 4 + corner, stored = state.corners[index];
    final first = grid.cellEdges[cell * 4 + (corner + 3) % 4], second = grid.cellEdges[cell * 4 + corner];
    final firstValue = state.edges[first], secondValue = state.edges[second];
    final known = stored & _countRange((firstValue == _line ? 1 : 0) + (secondValue == _line ? 1 : 0), (firstValue == _unknown ? 1 : 0) + (secondValue == _unknown ? 1 : 0));
    final counts = known & allowed;
    if (counts == 0) return false;
    if (counts != stored) {
      state.corners[index] = counts;
      // 只因边定下而收窄的，那一格与那个点在定边时已经排进下一轮；新推出的才要再排。
      if (counts != known) {
        _enqueue(cell);
        _enqueue(grid.cellCount + grid.cornerVertex(cell, corner));
      }
    }
    if (firstValue == _unknown && !_settleInCorner(state, first, secondValue, counts)) return false;
    final secondNow = state.edges[second];
    if (secondNow == _unknown && !_settleInCorner(state, second, state.edges[first], counts)) return false;
    return true;
  }

  // 角里的一条未定边：另一条边是 otherValue、这一角可能有 counts 条线时，是线、是叉哪种凑得出来；只有一种凑得出就定下。
  bool _settleInCorner(_LoopState state, int edge, int otherValue, int counts) {
    // 另一条边能贡献的线数：线 {1}、叉 {0}、未定 {0, 1}。
    final options = otherValue == _line ? 2 : otherValue == _cross ? 1 : 3;
    final canLine = (options << 1) & counts != 0, canCross = options & counts != 0;
    if (!canLine && !canCross) return false;
    if (!canLine) return _assign(state, edge, _cross);
    if (!canCross) return _assign(state, edge, _line);
    return true;
  }

  // 试探哪条边：线头里未定边最少（推理后至少还剩两条）、一样少时所在那段线最短的那个点的第一条未定边（先把零散的短线接起来，
  // 试过几种挑法，这样出专家档最快）；没有线头挑还差线最多的数字格；都没有取第一条未定边。
  int _choose(_LoopState state) {
    var best = -1, bestScore = 1 << 30;
    for (var vertex = 0; vertex < grid.vertexCount; vertex++) {
      if (state.degree[vertex] != 1) continue;
      var unknown = 0;
      for (var side = 0; side < 4; side++) {
        final edge = grid.vertexEdges[vertex * 4 + side];
        if (edge >= 0 && state.edges[edge] == _unknown) unknown++;
      }
      final score = unknown * 1000 + state.length[vertex];
      if (score < bestScore) (best, bestScore) = (vertex, score);
    }
    if (best >= 0) {
      for (var side = 0; side < 4; side++) {
        final edge = grid.vertexEdges[best * 4 + side];
        if (edge >= 0 && state.edges[edge] == _unknown) return edge;
      }
    }
    var neediest = -1, most = 0;
    for (var cell = 0; cell < grid.cellCount; cell++) {
      // 只看有确定数字的格（允许的线数只有一个）。
      final mask = allowed[cell];
      if (mask & (mask - 1) != 0) continue;
      final clue = mask.bitLength - 1;
      if (clue <= most) continue;
      var lines = 0, unknown = 0;
      for (var side = 0; side < 4; side++) {
        final value = state.edges[grid.cellEdges[cell * 4 + side]];
        if (value == _line) {
          lines++;
        } else if (value == _unknown) {
          unknown++;
        }
      }
      if (unknown > 0 && clue - lines > most) (neediest, most) = (cell, clue - lines);
    }
    if (neediest >= 0) {
      for (var side = 0; side < 4; side++) {
        final edge = grid.cellEdges[neediest * 4 + side];
        if (state.edges[edge] == _unknown) return edge;
      }
    }
    return state.edges.indexOf(_unknown);
  }
}

// 区域的边界：两边的格一个在区域里、一个不在（棋盘外算不在）的边是线。
List<bool> loopBoundary(List<bool> inside, LoopGrid grid) {
  bool within(int cell) => cell >= 0 && inside[cell];
  return [for (var edge = 0; edge < grid.edgeCount; edge++) within(grid.edgeCells[edge * 2]) != within(grid.edgeCells[edge * 2 + 1])];
}

// 每格四条边里有几条是线。
List<int> loopCounts(List<bool> lines, LoopGrid grid) => [
  for (var cell = 0; cell < grid.cellCount; cell++)
    [for (var side = 0; side < 4; side++) grid.cellEdges[cell * 4 + side]].where((edge) => lines[edge]).length,
];

class LoopRules extends PuzzleRules<LoopPuzzle, List<bool>> {
  const LoopRules();

  // 档位：入门 4 见方、简单 5 见方只靠推理就能解开（不用试探）；普通 6 见方起只要求唯一；困难 7 见方、专家 10 见方还要求光靠推理推不完
  // （要用到试探，不只是数字、点与格角的直接规则），并出几道候选留试探最多的（专家一道候选几十毫秒，只比两道）。
  static const _sides = {PuzzleTier.entry: 4, PuzzleTier.easy: 5, PuzzleTier.normal: 6, PuzzleTier.hard: 7, PuzzleTier.expert: 10};
  static const _candidates = {PuzzleTier.entry: 1, PuzzleTier.easy: 1, PuzzleTier.normal: 1, PuzzleTier.hard: 3, PuzzleTier.expert: 2};
  static const _removalBudget = 1000;

  @override
  PuzzleDraw<LoopPuzzle, List<bool>> generate(int seed, PuzzleTier tier) {
    final side = _sides[tier]!;
    final random = PuzzleRandom(seed);
    final guessing = tier.index >= PuzzleTier.normal.index, mustGuess = tier.index >= PuzzleTier.hard.index;
    PuzzleDraw<LoopPuzzle, List<bool>>? best;
    var bestBranches = -1, drawn = 0;
    while (drawn < _candidates[tier]!) {
      final draw = _draw(side, random, guessing: guessing);
      if (draw == null) continue;
      final branches = loopSolve(draw.puzzle).branches;
      if (mustGuess && branches == 0) continue;
      drawn++;
      if (branches > bestBranches) (best, bestBranches) = (draw, branches);
    }
    return best!;
  }

  // 一道候选：长出区域，它的边界就是答案，算出每格的数字（全给上还不唯一、或入门与简单档光靠推理解不开的区域不用，返回 null）；
  // 再按随机顺序逐个拿掉数字，拿掉后仍唯一就拿掉（入门与简单还要求仍能只靠推理解开），留下的每一个都少不了
  // （例外：证明拿不拿得掉要试探太多次的格留着，见 _stillUnique，专家档偶尔有一个）。
  static PuzzleDraw<LoopPuzzle, List<bool>>? _draw(int side, PuzzleRandom random, {required bool guessing}) {
    final grid = LoopGrid.of(side, side);
    final solution = loopBoundary(_region(side, side, random), grid);
    final clues = loopCounts(solution, grid);
    final full = loopSolve(LoopPuzzle(width: side, height: side, clues: clues));
    if (full.count != 1 || !guessing && full.branches > 0) return null;
    final order = [for (var cell = 0; cell < grid.cellCount; cell++) cell];
    random.shuffle(order);
    for (final cell in order) {
      final clue = clues[cell];
      clues[cell] = -1;
      final keep = guessing ? _stillUnique(side, clues, cell, clue, solution) : loopSolve(LoopPuzzle(width: side, height: side, clues: clues)).branches == 0;
      if (!keep) clues[cell] = clue;
    }
    return PuzzleDraw(LoopPuzzle(width: side, height: side, clues: List.unmodifiable(clues)), List.unmodifiable(solution));
  }

  // 拿掉一格的数字后是否仍唯一：拿掉之前只有一个解，拿掉之后多出来的解这一格的线数一定不是原来的数，
  // 所以只要找「这一格除了原来的数都行」有没有解（找到 1 个就停），比数到第 2 个解快得多（不用把原来那个解再走一遍）。
  // 试探超过 _removalBudget 次还没下结论就当拿不掉（留着一定唯一）：极少数格的证明要走几十万步，不设上限 10 见方偶尔要出好几秒。
  static bool _stillUnique(int side, List<int> clues, int cell, int removed, List<bool> solution) {
    final allowed = _allowedOf(clues)..[cell] = _anyClue & ~(1 << removed);
    final solver = _LoopSolver(side, side, allowed, guide: solution, budget: _removalBudget);
    return solver.solve(1).count == 0 && !solver.overBudget;
  }

  // 随机长出一块连通、不留洞的格子区域：从随机一格开始，每次在区域边上随机挑一格并进来；并进来会让外面的格被围住（外面不再连成一片）就不要。
  // 里外各连成一片，边界就是一条不分叉、不自交的回路。挨着区域两格以上的格多半跳过，区域才长出枝杈、回路弯得多。
  static List<bool> _region(int width, int height, PuzzleRandom random) {
    final cells = width * height;
    final target = (cells * (.42 + random.nextDouble() * .16)).round();
    final inside = List.filled(cells, false);
    inside[random.nextInt(cells)] = true;
    int touching(int cell) {
      final row = cell ~/ width, column = cell % width;
      return (row > 0 && inside[cell - width] ? 1 : 0) +
          (row < height - 1 && inside[cell + width] ? 1 : 0) +
          (column > 0 && inside[cell - 1] ? 1 : 0) +
          (column < width - 1 && inside[cell + 1] ? 1 : 0);
    }

    var size = 1;
    for (var attempt = 0; size < target && attempt < cells * 40; attempt++) {
      final frontier = [for (var cell = 0; cell < cells; cell++) if (!inside[cell] && touching(cell) > 0) cell];
      if (frontier.isEmpty) break;
      final cell = random.pick(frontier);
      final around = touching(cell);
      if (around > 1 && random.chance(around == 2 ? .5 : .8)) continue;
      inside[cell] = true;
      if (_outsideConnected(inside, width, height)) {
        size++;
      } else {
        inside[cell] = false;
      }
    }
    return inside;
  }

  // 区域外的格是否都能从棋盘外走到（上下左右相邻），即区域里没有洞。
  static bool _outsideConnected(List<bool> inside, int width, int height) {
    final seen = List.filled(width * height, false), stack = <int>[];
    var outside = 0;
    for (var cell = 0; cell < width * height; cell++) {
      if (inside[cell]) continue;
      outside++;
      final row = cell ~/ width, column = cell % width;
      if (row == 0 || row == height - 1 || column == 0 || column == width - 1) {
        seen[cell] = true;
        stack.add(cell);
      }
    }
    var reached = 0;
    while (stack.isNotEmpty) {
      final cell = stack.removeLast();
      reached++;
      final row = cell ~/ width, column = cell % width;
      for (final (next, ok) in [(cell - width, row > 0), (cell + width, row < height - 1), (cell - 1, column > 0), (cell + 1, column < width - 1)]) {
        if (ok && !inside[next] && !seen[next]) {
          seen[next] = true;
          stack.add(next);
        }
      }
    }
    return reached == outside;
  }

  // 恰好一条闭合的回路（每个点连 0 或 2 条线，从一条线出发走一圈能走遍全部的线），并且每个数字格四周的线数对得上。
  @override
  bool solved(LoopPuzzle puzzle, List<bool> answer) {
    final grid = LoopGrid.of(puzzle.width, puzzle.height);
    if (answer.length != grid.edgeCount || puzzle.clues.length != grid.cellCount) return false;
    final counts = loopCounts(answer, grid);
    for (var cell = 0; cell < grid.cellCount; cell++) {
      if (puzzle.clues[cell] >= 0 && puzzle.clues[cell] != counts[cell]) return false;
    }
    final degree = Uint8List(grid.vertexCount);
    var total = 0, start = -1;
    for (var edge = 0; edge < grid.edgeCount; edge++) {
      if (!answer[edge]) continue;
      total++;
      start = edge;
      degree[grid.edgeEnds[edge * 2]]++;
      degree[grid.edgeEnds[edge * 2 + 1]]++;
    }
    if (total == 0 || degree.any((count) => count != 0 && count != 2)) return false;
    final home = grid.edgeEnds[start * 2];
    var vertex = grid.edgeEnds[start * 2 + 1], previous = start, walked = 1;
    while (vertex != home) {
      var next = -1;
      for (var side = 0; side < 4; side++) {
        final edge = grid.vertexEdges[vertex * 4 + side];
        if (edge >= 0 && edge != previous && answer[edge]) next = edge;
      }
      vertex = grid.edgeEnds[next * 2] == vertex ? grid.edgeEnds[next * 2 + 1] : grid.edgeEnds[next * 2];
      previous = next;
      walked++;
    }
    return walked == total;
  }

  // 难度分口径：以边长为主（4、5、6、7 见方记 1、3、5、7，8 见方起记 9）；要试探的题试探分支数不少于格数的四分之一、
  // 只靠推理的题推理轮数不少于格数的一半，再加 1。五档各占两分（入门 1–2 到专家 9–10），同档最多差 1、档间不重叠。
  @override
  int difficulty(LoopPuzzle puzzle) {
    final result = loopSolve(puzzle);
    final side = (puzzle.width + puzzle.height) / 2;
    final base = (2 * side - 7).round().clamp(1, 9);
    final cells = puzzle.width * puzzle.height;
    final deep = result.branches > 0 ? result.branches * 4 >= cells : result.rounds * 2 >= cells;
    return (base + (deep ? 1 : 0)).clamp(1, 10);
  }

  @override
  Object encodePuzzle(LoopPuzzle puzzle) => {'width': puzzle.width, 'height': puzzle.height, 'clues': puzzle.clues};

  @override
  LoopPuzzle decodePuzzle(Object? json) {
    final width = puzzleInt(json, 'width', min: loopMinSide, max: loopMaxSide), height = puzzleInt(json, 'height', min: loopMinSide, max: loopMaxSide);
    final clues = puzzleInts((json as Map)['clues'], maxLength: loopMaxSide * loopMaxSide, min: -1, max: 3);
    if (clues.length != width * height) throw const FormatException('数字的格数不对');
    final puzzle = LoopPuzzle(width: width, height: height, clues: List.unmodifiable(clues));
    // 解不开或不止一个解的题当坏题拒收。
    if (loopSolve(puzzle).count != 1) throw const FormatException('题目不唯一');
    return puzzle;
  }

  // 答案按边的下标（见 LoopGrid）编成 0 与 1 的字符串，1 是线。
  @override
  Object encodeAnswer(List<bool> answer) => answer.map((line) => line ? '1' : '0').join();

  @override
  List<bool> decodeAnswer(Object? json) {
    final most = LoopGrid.of(loopMaxSide, loopMaxSide).edgeCount;
    if (json is! String || json.length > most || !RegExp(r'^[01]*$').hasMatch(json)) throw const FormatException('答案不合法');
    return [for (final char in json.split('')) char == '1'];
  }
}
