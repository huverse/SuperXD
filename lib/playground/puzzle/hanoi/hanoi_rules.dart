import 'dart:math' as math;
import 'dart:typed_data';

import 'package:superxd/playground/puzzle_rules.dart';

// 汉诺塔（题面写法第 2 版）：一次只挪一根柱子最上面的盘子，大盘不能压小盘，把开局摆成目标的样子。
// 开局与目标都是随机的合法局面（任意分配都合法；四分之一的题目标是全部叠到一根柱上），最少步数按这道题的规则在全部局面里广度优先求，
// 出题时让预计用时落在这一档的区间里（同认知测验里的 Tower of Hanoi 任务：随机起止局面、按最少步数控难度），同一档的题因此几乎不重样。
// 变体随档递进（参数写在 _kinds）：入门经典三柱；简单加一根空着的第四根柱（Reve 问题，开局与目标都空着同一根）；普通加循环（只能顺着箭头挪到下一根）；
// 困难加四柱相邻（只能挪到旁边的柱子）；专家四柱循环与四柱相邻加盘。三柱相邻不用：它的局面图是一条线，走出第一步后每一步都是唯一的，没有可想的。
// 每道题出之前核对这条规矩真起作用（hanoiLooser）：去掉方向限制、或拿掉空着的第四根柱，最少步数都会变。
class HanoiPuzzle {
  const HanoiPuzzle({required this.pegs, required this.variant, required this.start, required this.goal});
  final int pegs;
  final HanoiVariant variant;
  // start[盘号]、goal[盘号] = 所在柱子（从 0 起）；盘号 0 最小。同一根柱子上的盘子按大小自然叠放，所以任意分配都是合法局面。
  final List<int> start, goal;

  int get disks => start.length;

  // 目标是全部叠到一根柱上时为那根柱子，否则为空（挑战改目标只改这种题，见服务端 challenge_plan.ts）。
  int? get tower => goal.every((peg) => peg == goal.first) ? goal.first : null;
}

// 挪法的规矩，code 发出后不改（题面里存它）。
enum HanoiVariant {
  // 任意两根柱子之间都能挪。
  classic(0),
  // 只能挪到旁边的柱子（柱子排成一排，两头不相连）。
  adjacent(1),
  // 只能顺着一个方向挪到下一根，最后一根挪回第一根。
  cyclic(2);

  const HanoiVariant(this.code);
  final int code;
}

typedef HanoiMove = ({int from, int to});

const hanoiMinPegs = 3, hanoiMaxPegs = 4;
// 盘子数上限：局面数是柱子数的盘子数次方，四柱 8 盘 65536 个局面，搜一遍几毫秒；再多界面线程上求最少步数就慢了。
const hanoiMaxDisks = 8;
// 一局最多记这么多步（外部输入的上限；专家档最少 80 来步，留足走弯路的余地）。
const hanoiMaxMoves = 4096;

// 只看方向的规矩：这一步在这道题里许不许挪（不看盘子大小）。
bool hanoiAllowed(HanoiPuzzle puzzle, int from, int to) => _allowed(puzzle.pegs, puzzle.variant, from, to);

bool _allowed(int pegs, HanoiVariant variant, int from, int to) =>
    from != to &&
    from >= 0 &&
    to >= 0 &&
    from < pegs &&
    to < pegs &&
    switch (variant) {
      HanoiVariant.classic => true,
      HanoiVariant.adjacent => (from - to).abs() == 1,
      HanoiVariant.cyclic => to == (from + 1) % pegs,
    };

// 这一步合不合规：方向许可、起点有盘子、终点空着或最上面的盘子更大。stacks 是每根柱子从底到顶的盘号。
bool hanoiLegal(HanoiPuzzle puzzle, List<List<int>> stacks, HanoiMove move) {
  if (!hanoiAllowed(puzzle, move.from, move.to)) return false;
  final source = stacks[move.from];
  if (source.isEmpty) return false;
  final destination = stacks[move.to];
  return destination.isEmpty || destination.last > source.last;
}

// 每根柱子从底到顶的盘号（positions[盘号] = 柱子）。
List<List<int>> hanoiStacks(int pegs, List<int> positions) => [
  for (var peg = 0; peg < pegs; peg++) [for (var disk = positions.length - 1; disk >= 0; disk--) if (positions[disk] == peg) disk],
];

bool hanoiSameStacks(List<List<int>> left, List<List<int>> right) {
  for (var peg = 0; peg < left.length; peg++) {
    if (left[peg].length != right[peg].length) return false;
    for (var level = 0; level < left[peg].length; level++) {
      if (left[peg][level] != right[peg][level]) return false;
    }
  }
  return true;
}

// 按步重放，返回每根柱子从底到顶的盘号；有一步不合规返回 null。
List<List<int>>? hanoiReplay(HanoiPuzzle puzzle, Iterable<HanoiMove> moves) {
  final stacks = hanoiStacks(puzzle.pegs, puzzle.start);
  for (final move in moves) {
    if (!hanoiLegal(puzzle, stacks, move)) return null;
    stacks[move.to].add(stacks[move.from].removeLast());
  }
  return stacks;
}

// 最少步数与一条最短走法：按这道题的规则从开局广度优先搜到目标（循环的挪法不能原路退回，所以是有向图，只从开局往前搜）。
int hanoiMinMoves(HanoiPuzzle puzzle) => _HanoiSearch(puzzle.pegs, puzzle.variant, puzzle.disks, _encode(puzzle.start), stop: _encode(puzzle.goal)).steps[_encode(puzzle.goal)];

List<HanoiMove> hanoiSolution(HanoiPuzzle puzzle) => _HanoiSearch(puzzle.pegs, puzzle.variant, puzzle.disks, _encode(puzzle.start), stop: _encode(puzzle.goal)).path(_encode(puzzle.goal));

// 去掉这道题的特别之处后的最少步数（核对规矩真起作用）：相邻、循环去掉方向限制；四柱经典拿掉开局与目标都空着的那根柱（没有空着的为空）；三柱经典为空。
int? hanoiLooser(HanoiPuzzle puzzle) {
  if (puzzle.variant != HanoiVariant.classic) {
    return _HanoiSearch(puzzle.pegs, HanoiVariant.classic, puzzle.disks, _encode(puzzle.start), stop: _encode(puzzle.goal)).steps[_encode(puzzle.goal)];
  }
  if (puzzle.pegs == hanoiMinPegs) return null;
  final spare = [for (var peg = 0; peg < puzzle.pegs; peg++) peg].where((peg) => !puzzle.start.contains(peg) && !puzzle.goal.contains(peg)).firstOrNull;
  if (spare == null) return null;
  List<int> without(List<int> positions) => [for (final peg in positions) peg < spare ? peg : peg - 1];
  final start = _encode(without(puzzle.start)), goal = _encode(without(puzzle.goal));
  return _HanoiSearch(puzzle.pegs - 1, HanoiVariant.classic, puzzle.disks, start, stop: goal).steps[goal];
}

// 局面编号：每个盘子占两位，盘号 0 在最低位（三柱、四柱同一种编法，三柱用不到值为 3 的那些编号）。
int _encode(List<int> positions) {
  var state = 0;
  for (var disk = positions.length - 1; disk >= 0; disk--) {
    state = state << 2 | positions[disk];
  }
  return state;
}

List<int> _decode(int state, int disks) => [for (var disk = 0; disk < disks; disk++) state >> (2 * disk) & 3];

// 一次广度优先搜索：steps 是每个局面离开局的最少步数（到不了为 -1），parent 是最短走法上的前一个局面；给了 stop 搜到它就停。
class _HanoiSearch {
  _HanoiSearch(int pegs, HanoiVariant variant, this.disks, int start, {int? stop}) : steps = Int16List(1 << (2 * disks)), parent = Int32List(1 << (2 * disks)) {
    steps.fillRange(0, steps.length, -1);
    final pairs = <int>[
      for (var from = 0; from < pegs; from++)
        for (var to = 0; to < pegs; to++)
          if (_allowed(pegs, variant, from, to)) ...[from, to],
    ];
    final queue = Int32List(steps.length);
    final tops = Int8List(hanoiMaxPegs);
    var head = 0, tail = 0;
    steps[start] = 0;
    queue[tail++] = start;
    while (head < tail) {
      final state = queue[head++];
      if (state == stop) break;
      tops.fillRange(0, hanoiMaxPegs, -1);
      for (var disk = 0, rest = state; disk < disks; disk++, rest >>= 2) {
        if (tops[rest & 3] < 0) tops[rest & 3] = disk;
      }
      final next = steps[state] + 1;
      for (var index = 0; index < pairs.length; index += 2) {
        final from = pairs[index], to = pairs[index + 1];
        final disk = tops[from];
        if (disk < 0) continue;
        final above = tops[to];
        if (above >= 0 && above < disk) continue;
        final moved = state + (to - from) * (1 << (2 * disk));
        if (steps[moved] >= 0) continue;
        steps[moved] = next;
        parent[moved] = state;
        queue[tail++] = moved;
      }
    }
  }

  final int disks;
  final Int16List steps;
  final Int32List parent;

  // 从开局到 goal 的一条最短走法（goal 要已搜到）。
  List<HanoiMove> path(int goal) {
    final moves = <HanoiMove>[];
    for (var state = goal; steps[state] > 0; state = parent[state]) {
      final before = parent[state];
      for (var disk = 0; disk < disks; disk++) {
        final from = before >> (2 * disk) & 3, to = state >> (2 * disk) & 3;
        if (from != to) {
          moves.add((from: from, to: to));
          break;
        }
      }
    }
    return moves.reversed.toList();
  }
}

class HanoiRules extends PuzzleRules<HanoiPuzzle, List<HanoiMove>> {
  const HanoiRules();

  // 第 2 版：加柱子数、挪法与目标局面（第 1 版只有三柱经典、目标是一根柱），答案每步改成「起点 × 4 + 终点」。
  @override
  int get puzzleVersion => 2;

  // 挑战里的特性（[人工决策-2026-11-16 17:26:21] 见 puzzle_rules.dart 的 PuzzleRules.fragment）。
  @override
  int? fragment(HanoiPuzzle puzzle, List<HanoiMove> solution) => hanoiMinMoves(puzzle);
  @override
  PuzzleIntake? get intake => PuzzleIntake.goal;
  @override
  int? minimum(HanoiPuzzle puzzle) => hanoiMinMoves(puzzle);

  // 每档的几种题（出题时按种子挑一种）：柱子数、挪法、盘子数，spare 为真时开局与目标都空着同一根柱（四柱经典，第四根是周转用的）。
  static const _kinds = <PuzzleTier, List<({int pegs, HanoiVariant variant, int disks, bool spare})>>{
    PuzzleTier.entry: [(pegs: 3, variant: HanoiVariant.classic, disks: 4, spare: false)],
    PuzzleTier.easy: [(pegs: 3, variant: HanoiVariant.classic, disks: 5, spare: false), (pegs: 4, variant: HanoiVariant.classic, disks: 7, spare: true)],
    PuzzleTier.normal: [(pegs: 3, variant: HanoiVariant.cyclic, disks: 4, spare: false), (pegs: 4, variant: HanoiVariant.classic, disks: 8, spare: true)],
    PuzzleTier.hard: [(pegs: 3, variant: HanoiVariant.cyclic, disks: 5, spare: false), (pegs: 4, variant: HanoiVariant.adjacent, disks: 6, spare: false)],
    PuzzleTier.expert: [(pegs: 4, variant: HanoiVariant.cyclic, disks: 6, spare: false), (pegs: 4, variant: HanoiVariant.adjacent, disks: 7, spare: false)],
  };
  // 每档预计用时的区间（秒）：落在难度分 3、4、5、6、7 各自的区间里，五档不重叠。
  static const _window = {PuzzleTier.entry: (36, 54), PuzzleTier.easy: (57, 80), PuzzleTier.normal: (94, 130), PuzzleTier.hard: (153, 178), PuzzleTier.expert: (250, 280)};
  // 目标是全部叠到一根柱上的题占的比例。
  static const _towerShare = .25;

  // 出题：按种子挑这一档的一种题、定目标是不是一根柱（四分之一），随机摆开局（四柱经典空着一根），从开局搜一遍全部局面，
  // 在一根柱的几个目标或全部局面里挑预计用时落在这一档区间里的；再核对这条规矩真起作用（hanoiLooser 与最少步数不同），不满足就重摆开局。
  @override
  PuzzleDraw<HanoiPuzzle, List<HanoiMove>> generate(int seed, PuzzleTier tier) {
    final random = PuzzleRandom(seed);
    final kind = random.pick(_kinds[tier]!);
    final tower = random.chance(_towerShare);
    final (least, most) = _window[tier]!;
    while (true) {
      final spare = kind.spare ? random.nextInt(kind.pegs) : -1;
      final usable = [for (var peg = 0; peg < kind.pegs; peg++) if (peg != spare) peg];
      final start = [for (var disk = 0; disk < kind.disks; disk++) random.pick(usable)];
      final search = _HanoiSearch(kind.pegs, kind.variant, kind.disks, _encode(start));
      bool fits(int state) {
        final steps = search.steps[state];
        if (steps <= 0) return false;
        final seconds = _paced(kind.pegs, kind.variant, steps, tower: tower);
        return seconds >= least && seconds <= most;
      }

      final goals = tower
          ? [for (final peg in usable) if (fits(_encode(List.filled(kind.disks, peg)))) _encode(List.filled(kind.disks, peg))]
          : [
              for (var state = 0; state < search.steps.length; state++)
                if (fits(state) && (spare < 0 || !_decode(state, kind.disks).contains(spare)) && _decode(state, kind.disks).toSet().length > 1) state,
            ];
      if (goals.isEmpty) continue;
      final goal = random.pick(goals);
      final puzzle = HanoiPuzzle(pegs: kind.pegs, variant: kind.variant, start: start, goal: _decode(goal, kind.disks));
      if (kind.pegs == hanoiMaxPegs || kind.variant != HanoiVariant.classic) {
        if (hanoiLooser(puzzle) == search.steps[goal]) continue;
      }
      return PuzzleDraw(puzzle, search.path(goal));
    }
  }

  @override
  bool solved(HanoiPuzzle puzzle, List<HanoiMove> answer) {
    if (answer.length > hanoiMaxMoves) return false;
    final stacks = hanoiReplay(puzzle, answer);
    return stacks != null && hanoiSameStacks(stacks, hanoiStacks(puzzle.pegs, puzzle.goal));
  }

  // 预计用时：看题 10 秒（目标是摆成某个样子的要对着目标看，16 秒），加每一步的用时（点两下加想一想）：经典三柱 2.5 秒；三柱相邻 2 秒（每步只有一种走法）；
  // 循环 2.8 秒（挪回去要绕一圈）；四柱经典 4.5 秒（选择多，一般人走不出最短的路，要多走不少步）；四柱相邻 3.2 秒、四柱循环 3.4 秒。
  @override
  int expectedSeconds(HanoiPuzzle puzzle) => _paced(puzzle.pegs, puzzle.variant, hanoiMinMoves(puzzle), tower: puzzle.tower != null);

  static int _paced(int pegs, HanoiVariant variant, int moves, {required bool tower}) {
    final pace = switch ((pegs, variant)) {
      (3, HanoiVariant.classic) => 2.5,
      (3, HanoiVariant.adjacent) => 2.0,
      (3, HanoiVariant.cyclic) => 2.8,
      (_, HanoiVariant.classic) => 4.5,
      (_, HanoiVariant.adjacent) => 3.2,
      (_, HanoiVariant.cyclic) => 3.4,
    };
    return ((tower ? 10 : 16) + moves * pace).round();
  }

  // 难易分直接由预计用时定（用时已按最少步数与这种挪法每步要想多久算好）：难度分（puzzleDifficulty）的每一档再对半分成两级，
  // 预计用时的区间对齐难度分 3–7，所以入门 1–2、简单 3–4、普通 5–6、困难 7–8、专家 9–10，五档分段不重叠。
  @override
  int complexity(HanoiPuzzle puzzle) {
    final level = 1.4 * math.log(expectedSeconds(puzzle) / 10) / math.ln2;
    return ((level - 2.5) * 2).floor().clamp(0, 9) + 1;
  }

  @override
  Object encodePuzzle(HanoiPuzzle puzzle) => {'pegs': puzzle.pegs, 'variant': puzzle.variant.code, 'start': puzzle.start, 'goal': puzzle.goal};

  @override
  HanoiPuzzle decodePuzzle(Object? json) {
    final pegs = puzzleInt(json, 'pegs', min: hanoiMinPegs, max: hanoiMaxPegs);
    final code = puzzleInt(json, 'variant', min: 0, max: HanoiVariant.values.length - 1);
    final start = puzzleInts((json as Map)['start'], maxLength: hanoiMaxDisks, min: 0, max: pegs - 1);
    final goal = puzzleInts(json['goal'], maxLength: hanoiMaxDisks, min: 0, max: pegs - 1);
    if (start.isEmpty || goal.length != start.length) throw const FormatException('开局与目标的盘子数不一致');
    if (_encode(start) == _encode(goal)) throw const FormatException('开局已经是目标');
    return HanoiPuzzle(pegs: pegs, variant: HanoiVariant.values.firstWhere((variant) => variant.code == code), start: start, goal: goal);
  }

  // 每步编成「起点 × 4 + 终点」一个数（三柱、四柱同一种编法），最长 hanoiMaxMoves 步。
  @override
  Object encodeAnswer(List<HanoiMove> answer) => [for (final move in answer) move.from * hanoiMaxPegs + move.to];

  @override
  List<HanoiMove> decodeAnswer(Object? json) => [
    for (final code in puzzleInts(json, maxLength: hanoiMaxMoves, min: 0, max: hanoiMaxPegs * hanoiMaxPegs - 1)) (from: code ~/ hanoiMaxPegs, to: code % hanoiMaxPegs),
  ];
}
