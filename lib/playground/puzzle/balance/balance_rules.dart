import 'dart:math' as math;

import 'package:superxd/playground/puzzle_rules.dart';

// 天平称球：一组外观一样的球里恰有一个重量不同，用天平称有限次找出它（有的档还要说出它偏轻还是偏重）。
// 秤按「对手」规则回答，所以靠运气猜不中、要真推理：秤不预先定好假球，每称一次，在「和之前全部结果都对得上的候选（球 × 偏轻 / 偏重）」上
// 看左边重、右边重、平衡三种结果各剩下哪些候选，挑「剩下的候选还要称最多次才分得清」的那个（剩下的次数已经不够用的排在最前），
// 一样多时按这道题的种子与第几次挑。同一道题同样的称法回答一样，服务器按同一份规则重放就能核对。
// 为什么不按「剩下的候选最多」挑：只需找出的档里，剩 3 个可疑球、只剩 1 次时称 1 对 2，三种结果各剩 2 个候选，平局若挑到「平衡」，
// 剩下的是同一个球的偏轻与偏重，已经找出来了，称错了也能靠运气赢；按球数比又会让 13 个球的第一次 4 对 4 永远答「倾斜」，专家档最难的那一支从不出现。
// 按「还要称几次」挑就是标准的对手论证：称错一步（某个结果在剩下的次数里分不清）必定挑到分不清的结果，此后怎么称都分不清。

// 一道题：球数、最多称几次、是否已知那个球偏重、是否还要说出偏轻还是偏重、平局怎么答的种子。球按下标 0 起（页面上从 1 号叫起）。
class BalancePuzzle {
  const BalancePuzzle({required this.balls, required this.weighings, required this.knownHeavy, required this.direction, required this.seed});
  final int balls, weighings;
  final bool knownHeavy;
  // 指认时要说出偏轻还是偏重（已知偏重的题不用说）。
  final bool direction;
  final int seed;

  int get everyone => (1 << balls) - 1;
}

// 外部输入的边界：球最多 13 个（页面一排放得下的量、称 3 次只需找出的上限），最多称 3 次。
const balanceMinBalls = 3;
const balanceMaxBalls = 13;
const balanceMaxWeighings = 3;

// 称一次：左盘、右盘各放哪些球（下标升序）。
class BalanceWeighing {
  const BalanceWeighing(this.left, this.right);
  final List<int> left, right;
}

// 答案：依次的称法加最后的指认（哪个球，要说轻重的题再带偏重 true、偏轻 false，其余为 null）。
class BalanceAnswer {
  const BalanceAnswer(this.weighings, this.ball, [this.heavy]);
  final List<BalanceWeighing> weighings;
  final int ball;
  final bool? heavy;
}

// 称的结果：左边重（左盘沉下去）、右边重、平衡。
enum BalanceTilt { left, right, level }

// 还可能是假球的：heavy 是可能偏重的球的位集，light 是可能偏轻的。一个球两位都在就是还不知道偏轻还是偏重。
typedef BalanceSuspects = ({int heavy, int light});

// 一次称法不合规的原因：有一边空着、两边球数不一样；invalid 是同一个球放了两边或编号越界（只会出自外部输入）。
enum BalanceFault { empty, uneven, invalid }

// 指认的判定：解开（候选恰好就是这一个）、还确定不了（它还是候选，但不止它一个）、和称的结果对不上（它已经不是候选）。
enum BalanceVerdict { solved, undetermined, contradicts }

int balanceBits(int mask) {
  var count = 0;
  for (var rest = mask; rest != 0; rest &= rest - 1) {
    count++;
  }
  return count;
}

List<int> balanceMembers(int mask) => [for (var index = 0; mask >> index != 0; index++) if (mask & (1 << index) != 0) index];

int balanceMask(Iterable<int> balls) => balls.fold(0, (mask, ball) => mask | (1 << ball));

BalanceSuspects balanceStart(BalancePuzzle puzzle) => (heavy: puzzle.everyone, light: puzzle.knownHeavy ? 0 : puzzle.everyone);

// 两盘放的是 left、right（位集）时，三种结果各剩下哪些候选，按 BalanceTilt 的顺序：
// 左边重 = 左盘里可能偏重的或右盘里可能偏轻的；右边重反过来；平衡 = 没上秤的。
List<BalanceSuspects> balanceSplit(BalanceSuspects suspects, int left, int right) => [
  (heavy: suspects.heavy & left, light: suspects.light & right),
  (heavy: suspects.heavy & right, light: suspects.light & left),
  (heavy: suspects.heavy & ~(left | right), light: suspects.light & ~(left | right)),
];

BalanceFault? balanceFault(BalancePuzzle puzzle, List<int> left, List<int> right) {
  final (leftMask, rightMask) = (balanceMask(left), balanceMask(right));
  final inside = [...left, ...right].every((ball) => ball >= 0 && ball < puzzle.balls);
  if (!inside || balanceBits(leftMask) != left.length || balanceBits(rightMask) != right.length || leftMask & rightMask != 0) return BalanceFault.invalid;
  if (left.isEmpty || right.isEmpty) return BalanceFault.empty;
  if (left.length != right.length) return BalanceFault.uneven;
  return null;
}

// 秤的回答（第 index 次称，0 起；调用方先确认称法合规、次数没超）：见文件头。
BalanceTilt balanceRespond(BalancePuzzle puzzle, BalanceSuspects suspects, int left, int right, int index) {
  final remaining = puzzle.weighings - index - 1;
  final keys = [
    for (final next in balanceSplit(suspects, left, right))
      if (next.heavy | next.light == 0) -1 else _needed(_stateOf(puzzle, next), remaining, puzzle.direction),
  ];
  final top = keys.reduce(math.max);
  final tied = [for (final (tilt, key) in keys.indexed) if (key == top) tilt];
  if (tied.length == 1) return BalanceTilt.values[tied.single];
  // 平局：按种子与第几次挑（换语言照样能算：32 位乘法取低位再异或，交给 PuzzleRandom 打散）。
  final roll = PuzzleRandom((puzzle.seed ^ ((index + 1) * 0x9E3779B9)) & 0xFFFFFFFF).nextInt(tied.length);
  return BalanceTilt.values[tied[roll]];
}

// 还要称几次才分得清（最多数到 remaining + 1，即剩下的次数不够用）。
int _needed(_State state, int remaining, bool direction) {
  for (var rounds = 0; rounds <= remaining; rounds++) {
    if (_solvable(state, rounds, direction)) return rounds;
  }
  return remaining + 1;
}

// 按次重放：每次都合规、次数不超才往下走，返回每次的结果与最后的候选；有一次不合规返回 null。
({List<BalanceTilt> tilts, BalanceSuspects suspects})? balanceReplay(BalancePuzzle puzzle, List<BalanceWeighing> weighings) {
  if (weighings.length > puzzle.weighings) return null;
  var suspects = balanceStart(puzzle);
  final tilts = <BalanceTilt>[];
  for (final (index, weighing) in weighings.indexed) {
    if (balanceFault(puzzle, weighing.left, weighing.right) != null) return null;
    final (left, right) = (balanceMask(weighing.left), balanceMask(weighing.right));
    final tilt = balanceRespond(puzzle, suspects, left, right, index);
    tilts.add(tilt);
    suspects = balanceSplit(suspects, left, right)[tilt.index];
  }
  return (tilts: tilts, suspects: suspects);
}

// 指认 ball（要说轻重的题 heavy 是偏重 true、偏轻 false，其余为 null）在当前候选下算不算解开。
BalanceVerdict balanceVerdict(BalancePuzzle puzzle, BalanceSuspects suspects, int ball, bool? heavy) {
  if (ball < 0 || ball >= puzzle.balls || (heavy != null) != puzzle.direction) return BalanceVerdict.contradicts;
  final bit = 1 << ball;
  final pool = switch (heavy) {
    null => suspects.heavy | suspects.light,
    true => suspects.heavy,
    false => suspects.light,
  };
  if (pool & bit == 0) return BalanceVerdict.contradicts;
  final unique = heavy == null ? suspects.heavy | suspects.light == bit : pool == bit && (heavy ? suspects.light : suspects.heavy) == 0;
  return unique ? BalanceVerdict.solved : BalanceVerdict.undetermined;
}

// ---------- 求解器 ----------
// 球除了编号都一样，所以局面只看每类有几个：u 个两向都可能、h 个只可能偏重、l 个只可能偏轻、g 个确定是好球。
// 称法也只看每类各放几个到左右盘；两边都放好球等于都拿掉，左右镜像结果也镜像，这两种重复只留一种（13 个球的局面一共几十种，极小极大一下就搜完）。
typedef _State = (int u, int h, int l, int g);
typedef _Move = ({int uL, int uR, int hL, int hR, int lL, int lR, int gL, int gR});

_State _stateOf(BalancePuzzle puzzle, BalanceSuspects suspects) {
  final both = balanceBits(suspects.heavy & suspects.light);
  final heavy = balanceBits(suspects.heavy & ~suspects.light), light = balanceBits(suspects.light & ~suspects.heavy);
  return (both, heavy, light, puzzle.balls - both - heavy - light);
}

extension on _State {
  // 要分清的东西：要说轻重时是候选数，只需找出时是球数。分清 = 不超过 1 个。
  int measure(bool direction) => direction ? 2 * $1 + $2 + $3 : $1 + $2 + $3;
  bool done(bool direction) => measure(direction) <= 1;
  bool get empty => $1 + $2 + $3 == 0;
}

// 每类各放几个：先定左右盘上的可疑球，好球只补在少的一边（补齐两边球数，好球不够就不行）；左边的类数元组不小于右边的（镜像只留一种）。
List<_Move> _moves(_State state) {
  final (u, h, l, g) = state;
  final moves = <_Move>[];
  for (var uL = 0; uL <= u; uL++) {
    for (var uR = 0; uR <= u - uL; uR++) {
      for (var hL = 0; hL <= h; hL++) {
        for (var hR = 0; hR <= h - hL; hR++) {
          for (var lL = 0; lL <= l; lL++) {
            for (var lR = 0; lR <= l - lL; lR++) {
              final (left, right) = (uL + hL + lL, uR + hR + lR);
              if (left + right == 0) continue;
              final gL = math.max(0, right - left), gR = math.max(0, left - right);
              if (gL + gR > g) continue;
              final mirrored = [uL - uR, hL - hR, lL - lR, gL - gR].firstWhere((difference) => difference != 0, orElse: () => 0);
              if (mirrored < 0) continue;
              moves.add((uL: uL, uR: uR, hL: hL, hR: hR, lL: lL, lR: lR, gL: gL, gR: gR));
            }
          }
        }
      }
    }
  }
  return moves;
}

// 三种结果之后的局面（同 balanceSplit 的顺序）。
List<_State> _outcomes(_State state, _Move move) {
  final (u, h, l, g) = state;
  final total = u + h + l + g;
  _State of(int both, int heavy, int light) => (both, heavy, light, total - both - heavy - light);
  return [
    of(0, move.uL + move.hL, move.uR + move.lR),
    of(0, move.uR + move.hR, move.uL + move.lL),
    of(u - move.uL - move.uR, h - move.hL - move.hR, l - move.lL - move.lR),
  ];
}

final _solvableMemo = <(_State, int, bool), bool>{};

// 极小极大：rounds 次之内，不管秤怎么答都分得清。剪枝：要分清的东西超过 3^rounds 个时一定不行（每次最多分三份）。
bool _solvable(_State state, int rounds, bool direction) {
  if (state.done(direction)) return true;
  if (rounds == 0 || state.measure(direction) > math.pow(3, rounds)) return false;
  return _solvableMemo[(state, rounds, direction)] ??= _moves(state).any((move) => _winning(state, move, rounds, direction));
}

bool _winning(_State state, _Move move, int rounds, bool direction) => _outcomes(state, move).every((next) => next.empty || _solvable(next, rounds - 1, direction));

// 这道题在限定次数内一定找得出（不管秤怎么答）。
bool balanceSolvable(BalancePuzzle puzzle) => _solvable(_stateOf(puzzle, balanceStart(puzzle)), puzzle.weighings, puzzle.direction);

// 参考解：每一步取第一个「不管秤怎么答都还来得及」的称法，具体放哪几个球按编号从小取，秤按规则回答，最后指认剩下的那一个。题目解不开返回 null。
BalanceAnswer? balanceSolve(BalancePuzzle puzzle) {
  if (!balanceSolvable(puzzle)) return null;
  var suspects = balanceStart(puzzle);
  final weighings = <BalanceWeighing>[];
  for (var index = 0; index < puzzle.weighings; index++) {
    final state = _stateOf(puzzle, suspects);
    if (state.done(puzzle.direction)) break;
    final move = _moves(state).firstWhere((move) => _winning(state, move, puzzle.weighings - index, puzzle.direction));
    final weighing = _place(puzzle, suspects, move);
    weighings.add(weighing);
    final (left, right) = (balanceMask(weighing.left), balanceMask(weighing.right));
    suspects = balanceSplit(suspects, left, right)[balanceRespond(puzzle, suspects, left, right, index).index];
  }
  final ball = balanceMembers(suspects.heavy | suspects.light).first;
  return BalanceAnswer(weighings, ball, puzzle.direction ? suspects.heavy != 0 : null);
}

// 把按类数的称法落到具体的球上：每类按编号从小取，先放左盘再放右盘。
BalanceWeighing _place(BalancePuzzle puzzle, BalanceSuspects suspects, _Move move) {
  final both = balanceMembers(suspects.heavy & suspects.light);
  final heavy = balanceMembers(suspects.heavy & ~suspects.light), light = balanceMembers(suspects.light & ~suspects.heavy);
  final good = balanceMembers(puzzle.everyone & ~(suspects.heavy | suspects.light));
  return BalanceWeighing(
    [...both.take(move.uL), ...heavy.take(move.hL), ...light.take(move.lL), ...good.take(move.gL)]..sort(),
    [...both.skip(move.uL).take(move.uR), ...heavy.skip(move.hL).take(move.hR), ...light.skip(move.lL).take(move.lR), ...good.skip(move.gL).take(move.gR)]..sort(),
  );
}

final _treeMemo = <(_State, int, bool), double>{};

// 整棵策略树的选择量（比特）：一套完整的称法要接得住秤的每一种回答，每到一处都要从全部称法（按类数、去掉重复）里挑出来得及的，
// 挑中要的信息量是 log2(全部 / 来得及的)；来得及的有几种时按均匀挑取平均，每种回答下面接着累加。
double _treeBits(_State state, int rounds, bool direction) {
  if (state.done(direction)) return 0;
  final key = (state, rounds, direction);
  if (_treeMemo[key] case final bits?) return bits;
  final moves = _moves(state);
  final good = [for (final move in moves) if (_winning(state, move, rounds, direction)) move];
  var below = 0.0;
  for (final move in good) {
    for (final next in _outcomes(state, move)) {
      if (!next.empty) below += _treeBits(next, rounds - 1, direction);
    }
  }
  return _treeMemo[key] = math.log(moves.length / good.length) / math.ln2 + below / good.length;
}

class BalanceRules extends PuzzleRules<BalancePuzzle, BalanceAnswer> {
  const BalanceRules();

  // 每档的参数。简单档原建议 4 个球称 2 次，求解器量出来比入门还容易（选择量 3.4 比特，入门 9.0），档位会倒挂，
  // 改成 9 个球不知轻重称 3 次（12.7 比特）：同样 9 个球，不知道轻重了多给一次。每档都核对过在次数内一定能找出（测试守护）。
  static const _tiers = {
    PuzzleTier.entry: (balls: 9, weighings: 2, knownHeavy: true, direction: false),
    PuzzleTier.easy: (balls: 9, weighings: 3, knownHeavy: false, direction: false),
    PuzzleTier.normal: (balls: 12, weighings: 3, knownHeavy: false, direction: false),
    PuzzleTier.hard: (balls: 12, weighings: 3, knownHeavy: false, direction: true),
    PuzzleTier.expert: (balls: 13, weighings: 3, knownHeavy: false, direction: false),
  };

  // 出题：参数按档定，种子定平局时秤怎么答（第一次称就有平局，走到哪一支、最后是哪个球都跟着变）；出题前用求解器确认一定找得出。
  @override
  PuzzleDraw<BalancePuzzle, BalanceAnswer> generate(int seed, PuzzleTier tier) {
    final plan = _tiers[tier]!;
    final puzzle = BalancePuzzle(balls: plan.balls, weighings: plan.weighings, knownHeavy: plan.knownHeavy, direction: plan.direction, seed: PuzzleRandom(seed).nextUint32());
    final solution = balanceSolve(puzzle);
    if (solution == null) throw StateError('天平称球 ${tier.name} 档在 ${plan.weighings} 次内找不出');
    return PuzzleDraw(puzzle, solution);
  }

  @override
  bool solved(BalancePuzzle puzzle, BalanceAnswer answer) {
    if ((answer.heavy != null) != puzzle.direction) return false;
    final replay = balanceReplay(puzzle, answer.weighings);
    return replay != null && balanceVerdict(puzzle, replay.suspects, answer.ball, answer.heavy) == BalanceVerdict.solved;
  }

  // 难度分口径：整棵策略树的选择量（_treeBits）÷ 2 − 3.5，取整夹在 1–10。参数只由档定、种子不影响，所以同档同分。
  // 实测：入门 9 个已知偏重称 2 次 9.0 比特 → 1；简单 9 个称 3 次 12.7 → 3；普通 12 个称 3 次 22.9 → 8；
  // 困难 12 个称 3 次还要说轻重 24.9 → 9；专家 13 个称 3 次 26.8 → 10。普通以上三档都是一次 4 对 4 起手的满载题，推理量本来就接近，所以挤在高分段。
  // 解不开的题面（出题与解码都会拦下）按 10 分算。
  @override
  int difficulty(BalancePuzzle puzzle) {
    if (!balanceSolvable(puzzle)) return 10;
    final bits = _treeBits(_stateOf(puzzle, balanceStart(puzzle)), puzzle.weighings, puzzle.direction);
    return (bits / 2 - 3.5).round().clamp(1, 10);
  }

  @override
  Object encodePuzzle(BalancePuzzle puzzle) => {
    'balls': puzzle.balls,
    'weighings': puzzle.weighings,
    'knownHeavy': puzzle.knownHeavy,
    'direction': puzzle.direction,
    'seed': puzzle.seed,
  };

  // 外部输入：球数、次数、种子逐项校验；已知偏重就不用说轻重，两个都为真的不收；在次数内找不出的不是题。
  @override
  BalancePuzzle decodePuzzle(Object? json) {
    final balls = puzzleInt(json, 'balls', min: balanceMinBalls, max: balanceMaxBalls);
    final weighings = puzzleInt(json, 'weighings', min: 1, max: balanceMaxWeighings);
    final seed = puzzleInt(json, 'seed', min: 0, max: 0xFFFFFFFF);
    final (knownHeavy, direction) = ((json as Map)['knownHeavy'], json['direction']);
    if (knownHeavy is! bool || direction is! bool || knownHeavy && direction) throw const FormatException('题目字段不合法');
    final puzzle = BalancePuzzle(balls: balls, weighings: weighings, knownHeavy: knownHeavy, direction: direction, seed: seed);
    if (!balanceSolvable(puzzle)) throw const FormatException('这道题在限定次数内找不出');
    return puzzle;
  }

  // 答案编成 {'weighings': [[左盘的球, 右盘的球], …], 'ball': 指认的球, 'heavy': 偏重 true / 偏轻 false（不用说轻重的题不写）}。
  @override
  Object encodeAnswer(BalanceAnswer answer) => {
    'weighings': [
      for (final weighing in answer.weighings) [[...weighing.left], [...weighing.right]],
    ],
    'ball': answer.ball,
    if (answer.heavy != null) 'heavy': answer.heavy,
  };

  // 只核对结构：次数不超过上限、每次是左右两组编号、同一次里一个球不放两边也不重复；两边球数等不等、编号在不在这道题里由 solved 按规则判。
  @override
  BalanceAnswer decodeAnswer(Object? json) {
    final raw = json is Map ? json['weighings'] : null;
    if (raw is! List || raw.length > balanceMaxWeighings) throw const FormatException('答案不合法');
    final weighings = [
      for (final item in raw)
        () {
          if (item is! List || item.length != 2) throw const FormatException('答案不合法');
          final left = puzzleInts(item[0], maxLength: balanceMaxBalls, min: 0, max: balanceMaxBalls - 1);
          final right = puzzleInts(item[1], maxLength: balanceMaxBalls, min: 0, max: balanceMaxBalls - 1);
          if ({...left, ...right}.length != left.length + right.length) throw const FormatException('答案不合法');
          return BalanceWeighing(left, right);
        }(),
    ];
    final ball = puzzleInt(json, 'ball', min: 0, max: balanceMaxBalls - 1);
    final heavy = (json as Map)['heavy'];
    if (heavy != null && heavy is! bool) throw const FormatException('答案不合法');
    return BalanceAnswer(weighings, ball, heavy as bool?);
  }
}
