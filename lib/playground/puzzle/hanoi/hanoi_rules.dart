import 'dart:math' as math;

import 'package:superxd/playground/puzzle_rules.dart';

// 汉诺塔：三根柱子，一次只挪最上面的一个盘子，大盘不能压小盘，把全部盘子挪到目标柱。
// 入门到普通是经典开局（全在第一根、挪到第三根），困难与专家打乱开局（每个盘子随机在某根柱子上，仍是合法叠放），最少步数按开局算。
class HanoiPuzzle {
  const HanoiPuzzle({required this.disks, required this.start, required this.target});
  final int disks;
  // start[盘号] = 所在柱子（0–2）；盘号 0 最小。同一根柱子上的盘子按大小自然叠放，所以任意分配都是合法开局。
  final List<int> start;
  final int target;
}

typedef HanoiMove = ({int from, int to});

const hanoiPegs = 3;
const hanoiMaxDisks = 10;
// 一局最多记这么多步（外部输入的上限；专家档最少 127 步，留足走弯路的余地）。
const hanoiMaxMoves = 4096;

// 从开局按最优走法挪到目标柱的最少步数：从最大的盘子看起，已在目标柱就不用动它，否则先把比它小的全挪到第三根柱子，再挪它，再把小的全挪回来。
int hanoiMinMoves(List<int> start, int target) {
  var moves = 0;
  var goal = target;
  for (var disk = start.length - 1; disk >= 0; disk--) {
    if (start[disk] == goal) continue;
    moves += 1 << disk;
    goal = hanoiPegs - start[disk] - goal;
  }
  return moves;
}

// 按步重放，返回每根柱子从底到顶的盘号；有一步不合法返回 null。
List<List<int>>? hanoiReplay(HanoiPuzzle puzzle, Iterable<HanoiMove> moves) {
  final pegs = hanoiStacks(puzzle);
  for (final move in moves) {
    if (!hanoiLegal(pegs, move)) return null;
    pegs[move.to].add(pegs[move.from].removeLast());
  }
  return pegs;
}

List<List<int>> hanoiStacks(HanoiPuzzle puzzle) => [
  for (var peg = 0; peg < hanoiPegs; peg++) [for (var disk = puzzle.disks - 1; disk >= 0; disk--) if (puzzle.start[disk] == peg) disk],
];

bool hanoiLegal(List<List<int>> pegs, HanoiMove move) {
  if (move.from == move.to || move.from < 0 || move.from >= hanoiPegs || move.to < 0 || move.to >= hanoiPegs) return false;
  final source = pegs[move.from];
  if (source.isEmpty) return false;
  final destination = pegs[move.to];
  return destination.isEmpty || destination.last > source.last;
}

class HanoiRules extends PuzzleRules<HanoiPuzzle, List<HanoiMove>> {
  const HanoiRules();

  static const _disks = {PuzzleTier.entry: 3, PuzzleTier.easy: 4, PuzzleTier.normal: 5, PuzzleTier.hard: 6, PuzzleTier.expert: 7};

  @override
  PuzzleDraw<HanoiPuzzle, List<HanoiMove>> generate(int seed, PuzzleTier tier) {
    final disks = _disks[tier]!;
    final random = PuzzleRandom(seed);
    var start = List.filled(disks, 0);
    var target = hanoiPegs - 1;
    if (tier.index >= PuzzleTier.hard.index) {
      // 打乱开局至少要走经典开局的一半，免得随机到几步就完的局面。
      do {
        start = [for (var disk = 0; disk < disks; disk++) random.nextInt(hanoiPegs)];
        target = random.nextInt(hanoiPegs);
      } while (hanoiMinMoves(start, target) < 1 << (disks - 1));
    }
    final puzzle = HanoiPuzzle(disks: disks, start: start, target: target);
    return PuzzleDraw(puzzle, hanoiSolution(puzzle));
  }

  @override
  bool solved(HanoiPuzzle puzzle, List<HanoiMove> answer) {
    if (answer.length > hanoiMaxMoves) return false;
    final pegs = hanoiReplay(puzzle, answer);
    return pegs != null && pegs[puzzle.target].length == puzzle.disks;
  }

  // 最少步数的对数：经典 3 盘约 2 分、7 盘约 7 分。
  @override
  int difficulty(HanoiPuzzle puzzle) {
    final moves = hanoiMinMoves(puzzle.start, puzzle.target);
    return (math.log(moves + 1) / math.ln2 * 1.25 - 1.5).round().clamp(1, 10);
  }

  @override
  Object encodePuzzle(HanoiPuzzle puzzle) => {'disks': puzzle.disks, 'start': puzzle.start, 'target': puzzle.target};

  @override
  HanoiPuzzle decodePuzzle(Object? json) {
    final disks = puzzleInt(json, 'disks', min: 1, max: hanoiMaxDisks);
    final start = puzzleInts((json as Map)['start'], maxLength: hanoiMaxDisks, min: 0, max: hanoiPegs - 1);
    if (start.length != disks) throw const FormatException('开局与盘子数不一致');
    return HanoiPuzzle(disks: disks, start: start, target: puzzleInt(json, 'target', min: 0, max: hanoiPegs - 1));
  }

  // 每步编成「起点 × 3 + 终点」一个数，最长 hanoiMaxMoves 步。
  @override
  Object encodeAnswer(List<HanoiMove> answer) => [for (final move in answer) move.from * hanoiPegs + move.to];

  @override
  List<HanoiMove> decodeAnswer(Object? json) => [
    for (final code in puzzleInts(json, maxLength: hanoiMaxMoves, min: 0, max: hanoiPegs * hanoiPegs - 1)) (from: code ~/ hanoiPegs, to: code % hanoiPegs),
  ];
}

// 最优解：同 hanoiMinMoves 的递推，逐个盘子把它挪到当时的目标柱。
List<HanoiMove> hanoiSolution(HanoiPuzzle puzzle) {
  final position = [...puzzle.start];
  final moves = <HanoiMove>[];
  void place(int disk, int goal) {
    if (disk < 0) return;
    if (position[disk] == goal) return place(disk - 1, goal);
    final spare = hanoiPegs - position[disk] - goal;
    place(disk - 1, spare);
    moves.add((from: position[disk], to: goal));
    position[disk] = goal;
    place(disk - 1, goal);
  }

  place(puzzle.disks - 1, puzzle.target);
  return moves;
}
