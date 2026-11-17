import 'dart:math' as math;

import 'package:superxd/playground/puzzle_rules.dart';

// 天平称球：一组外观一样的球里有一个（或两个一样重的）重量不同，用天平称有限次找出来（有的题还要说出偏轻还是偏重）。
// 题型照经典称球问题的几种变体（理论上限见 Dyson 1946，测试拿求解器逐条核对）：
// 1. 已知那个球偏重（或偏轻）：称 k 次最多分得清 3^k 个。
// 2. 不知轻重、只要找出：最多 (3^k − 1) / 2 个；另给一个标准球（确定是真的，可以上秤）时 (3^k + 1) / 2 个。
// 3. 不知轻重、还要说出轻重：最多 (3^k − 3) / 2 个；有标准球时 (3^k − 1) / 2 个。
// 4. 两个一样重的假球（已知都偏重或都偏轻）：一边各放一个就平衡；C(n, 2) ≤ 3^k 只是信息下界，以求解器为准（7 个称 3 次可以，8 个不行）。
// 每档的题型、球数与次数在档内随机（_pools），每道题都核对过：给的次数一定找得出、少一次一定不行（上限是紧的）。
// 秤按「对手」规则回答，所以靠运气猜不中、要真推理：秤不预先定好假球，每称一次，在「和之前全部结果都对得上的候选」上
// 看左边重、右边重、平衡三种结果各剩下哪些候选，挑「剩下的候选还要称最多次才分得清」的那个（剩下的次数已经不够用的排在最前），
// 一样多时按这道题的种子与第几次挑。同一道题同样的称法回答一样，服务器按同一份规则重放就能核对。
// 为什么不按「剩下的候选最多」挑：只需找出的档里，剩 3 个可疑球、只剩 1 次时称 1 对 2，三种结果各剩 2 个候选，平局若挑到「平衡」，
// 剩下的是同一个球的偏轻与偏重，已经找出来了，称错了也能靠运气赢；按球数比又会让 13 个球的第一次 4 对 4 永远答「倾斜」，专家档最难的那一支从不出现。
// 按「还要称几次」挑就是标准的对手论证：称错一步（某个结果在剩下的次数里分不清）必定挑到分不清的结果，此后怎么称都分不清；
// 上限又是紧的，每称一次「还要称几次」最多少 1，所以次数用完之前也不会提前分清。

// 假球偏哪边：已知偏重、已知偏轻、不知道。题面里写 name，发出后不改。
enum BalanceWeight { heavy, light, unknown }

// 一道题：candidates 个可能是假球的球（下标 0 起，页面上从 1 号叫起）、standards 个标准球（下标接在后面，确定是真的）、
// fakes 个假球（两个时一样重）、偏哪边、是否还要说出偏轻还是偏重（只有不知轻重时才可能要）、最多称几次、平局怎么答的种子。
class BalancePuzzle {
  const BalancePuzzle({required this.balls, required this.weighings, required this.weight, this.direction = false, this.standards = 0, this.fakes = 1, required this.seed});
  final int balls, weighings, standards, fakes, seed;
  final BalanceWeight weight;
  final bool direction;

  // 桌上一共几个球（含标准球）。
  int get total => balls + standards;
  int get everyone => (1 << balls) - 1;
  bool get paired => fakes == 2;
}

// 外部输入的边界：可疑的球 3 到 16 个、标准球最多 1 个、桌上一共最多 16 个（360 宽加 1.3 倍字号时桌面三排、一个盘三列三排放得下），
// 两个假球时最多 8 个（球对最多 28 个，位集在服务端的 32 位运算里也放得下），最多称 4 次。
const balanceMinBalls = 3;
const balanceMaxBalls = 16;
const balanceMaxStandards = 1;
const balanceMaxTotal = 16;
const balanceMaxPairBalls = 8;
const balanceMaxWeighings = 4;

// 称一次：左盘、右盘各放哪些球（下标升序，可以有标准球）。
class BalanceWeighing {
  const BalanceWeighing(this.left, this.right);
  final List<int> left, right;
}

// 答案：依次的称法加最后的指认（一个假球是一个球、两个假球是两个球，升序；要说轻重的题再带偏重 true、偏轻 false，其余为 null）。
class BalanceAnswer {
  const BalanceAnswer(this.weighings, this.balls, [this.heavy]);
  final List<BalanceWeighing> weighings;
  final List<int> balls;
  final bool? heavy;
}

// 称的结果：左边重（左盘沉下去）、右边重、平衡。
enum BalanceTilt { left, right, level }

// 还可能的情况：一个假球时 heavy 是可能偏重的球的位集、light 是可能偏轻的（一个球两位都在就是还不知道轻重）；
// 两个假球时 pairs 是还可能的球对的位集（球对按 balancePairs 的顺序）。用不到的位集是 0。
typedef BalanceSuspects = ({int heavy, int light, int pairs});

// 一次称法不合规的原因：有一边空着、两边球数不一样；invalid 是同一个球放了两边或编号越界（只会出自外部输入）。
enum BalanceFault { empty, uneven, invalid }

// 指认的判定：解开（候选恰好就是这一个或这一对）、还确定不了（它还是候选，但不止它一个）、和称的结果对不上（它已经不是候选）。
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

// n 个球的全部球对：(0, 1)、(0, 2)、…、(1, 2)、…，下标就是 pairs 位集里的位。
List<(int, int)> balancePairs(int balls) => _pairLists[balls] ??= [
  for (var first = 0; first < balls; first++)
    for (var second = first + 1; second < balls; second++) (first, second),
];
final _pairLists = <int, List<(int, int)>>{};

// 球对 (first, second)（first < second）在 balancePairs 里的下标。
int balancePairIndex(int balls, int first, int second) => first * (2 * balls - first - 1) ~/ 2 + second - first - 1;

BalanceSuspects balanceStart(BalancePuzzle puzzle) => puzzle.paired
    ? (heavy: 0, light: 0, pairs: (1 << balancePairs(puzzle.balls).length) - 1)
    : (heavy: puzzle.weight == BalanceWeight.light ? 0 : puzzle.everyone, light: puzzle.weight == BalanceWeight.heavy ? 0 : puzzle.everyone, pairs: 0);

bool _empty(BalanceSuspects suspects) => suspects.heavy | suspects.light | suspects.pairs == 0;

// 两盘放的是 left、right（位集）时，三种结果各剩下哪些候选，按 BalanceTilt 的顺序：
// 一个假球：左边重 = 左盘里可能偏重的或右盘里可能偏轻的；右边重反过来；平衡 = 没上秤的。
// 两个假球：数一对里各有几个在左盘、几个在右盘，多的那边沉（偏重时）或翘（偏轻时），一样多就平衡。
List<BalanceSuspects> balanceSplit(BalancePuzzle puzzle, BalanceSuspects suspects, int left, int right) {
  if (!puzzle.paired) {
    return [
      (heavy: suspects.heavy & left, light: suspects.light & right, pairs: 0),
      (heavy: suspects.heavy & right, light: suspects.light & left, pairs: 0),
      (heavy: suspects.heavy & ~(left | right), light: suspects.light & ~(left | right), pairs: 0),
    ];
  }
  final parts = _pairSplit(puzzle.balls, suspects.pairs, left, right);
  final (down, up) = puzzle.weight == BalanceWeight.light ? (parts[1], parts[0]) : (parts[0], parts[1]);
  return [
    for (final pairs in [down, up, parts[2]]) (heavy: 0, light: 0, pairs: pairs),
  ];
}

// 按「多的一边」把球对分三份：左边多、右边多、一样多。
List<int> _pairSplit(int balls, int mask, int left, int right) {
  final parts = [0, 0, 0];
  for (final (index, (first, second)) in balancePairs(balls).indexed) {
    if (mask & (1 << index) == 0) continue;
    final onLeft = (left >> first & 1) + (left >> second & 1), onRight = (right >> first & 1) + (right >> second & 1);
    parts[onLeft > onRight ? 0 : onLeft < onRight ? 1 : 2] |= 1 << index;
  }
  return parts;
}

BalanceFault? balanceFault(BalancePuzzle puzzle, List<int> left, List<int> right) {
  final (leftMask, rightMask) = (balanceMask(left), balanceMask(right));
  final inside = [...left, ...right].every((ball) => ball >= 0 && ball < puzzle.total);
  if (!inside || balanceBits(leftMask) != left.length || balanceBits(rightMask) != right.length || leftMask & rightMask != 0) return BalanceFault.invalid;
  if (left.isEmpty || right.isEmpty) return BalanceFault.empty;
  if (left.length != right.length) return BalanceFault.uneven;
  return null;
}

// 秤的回答（第 index 次称，0 起；调用方先确认称法合规、次数没超）：见文件头。
BalanceTilt balanceRespond(BalancePuzzle puzzle, BalanceSuspects suspects, int left, int right, int index) {
  final remaining = puzzle.weighings - index - 1;
  final keys = [
    for (final next in balanceSplit(puzzle, suspects, left, right))
      if (_empty(next)) -1 else _needed(puzzle, next, remaining),
  ];
  final top = keys.reduce(math.max);
  final tied = [for (final (tilt, key) in keys.indexed) if (key == top) tilt];
  if (tied.length == 1) return BalanceTilt.values[tied.single];
  // 平局：按种子与第几次挑（换语言照样能算：32 位乘法取低位再异或，交给 PuzzleRandom 打散）。
  final roll = PuzzleRandom((puzzle.seed ^ ((index + 1) * 0x9E3779B9)) & 0xFFFFFFFF).nextInt(tied.length);
  return BalanceTilt.values[tied[roll]];
}

// 还要称几次才分得清（最多数到 remaining + 1，即剩下的次数不够用）。
int _needed(BalancePuzzle puzzle, BalanceSuspects suspects, int remaining) {
  for (var rounds = 0; rounds <= remaining; rounds++) {
    if (_solvableFrom(puzzle, suspects, rounds)) return rounds;
  }
  return remaining + 1;
}

bool _solvableFrom(BalancePuzzle puzzle, BalanceSuspects suspects, int rounds) =>
    puzzle.paired ? _pairSolvable(puzzle.balls, suspects.pairs, rounds) : _solvable(_stateOf(puzzle, suspects), rounds, puzzle.direction);

// 已经分清了：只剩一种可能（一个假球只需找出时，只剩一个球就算，不管轻重）。
bool balanceDone(BalancePuzzle puzzle, BalanceSuspects suspects) => _solvableFrom(puzzle, suspects, 0);

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
    suspects = balanceSplit(puzzle, suspects, left, right)[tilt.index];
  }
  return (tilts: tilts, suspects: suspects);
}

// 指认 balls（一个假球一个、两个假球两个；要说轻重的题 heavy 是偏重 true、偏轻 false，其余为 null）在当前候选下算不算解开。
// 个数不对、有重复、指了标准球或越界的都算对不上。
BalanceVerdict balanceVerdict(BalancePuzzle puzzle, BalanceSuspects suspects, List<int> balls, bool? heavy) {
  final sorted = [...balls]..sort();
  final valid = sorted.length == puzzle.fakes && sorted.toSet().length == sorted.length && sorted.every((ball) => ball >= 0 && ball < puzzle.balls);
  if (!valid || (heavy != null) != puzzle.direction) return BalanceVerdict.contradicts;
  if (puzzle.paired) {
    final bit = 1 << balancePairIndex(puzzle.balls, sorted[0], sorted[1]);
    if (suspects.pairs & bit == 0) return BalanceVerdict.contradicts;
    return suspects.pairs == bit ? BalanceVerdict.solved : BalanceVerdict.undetermined;
  }
  final bit = 1 << sorted.single;
  final pool = switch (heavy) {
    null => suspects.heavy | suspects.light,
    true => suspects.heavy,
    false => suspects.light,
  };
  if (pool & bit == 0) return BalanceVerdict.contradicts;
  final unique = heavy == null ? suspects.heavy | suspects.light == bit : pool == bit && (heavy ? suspects.light : suspects.heavy) == 0;
  return unique ? BalanceVerdict.solved : BalanceVerdict.undetermined;
}

// ---------- 一个假球的求解器 ----------
// 球除了编号都一样，所以局面只看每类有几个：u 个两向都可能、h 个只可能偏重、l 个只可能偏轻、g 个确定是好球（标准球一开始就在这里）。
// 称法也只看每类各放几个到左右盘；两边都放好球等于都拿掉，左右镜像结果也镜像，这两种重复只留一种（16 个球的局面一共几百种，极小极大一下就搜完）。
typedef _State = (int u, int h, int l, int g);
typedef _Move = ({int uL, int uR, int hL, int hR, int lL, int lR, int gL, int gR});

_State _stateOf(BalancePuzzle puzzle, BalanceSuspects suspects) {
  final both = balanceBits(suspects.heavy & suspects.light);
  final heavy = balanceBits(suspects.heavy & ~suspects.light), light = balanceBits(suspects.light & ~suspects.heavy);
  return (both, heavy, light, puzzle.total - both - heavy - light);
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

// 把按类数的称法落到具体的球上：每类按编号从小取，先放左盘再放右盘。
BalanceWeighing _place(BalancePuzzle puzzle, BalanceSuspects suspects, _Move move) {
  final both = balanceMembers(suspects.heavy & suspects.light);
  final heavy = balanceMembers(suspects.heavy & ~suspects.light), light = balanceMembers(suspects.light & ~suspects.heavy);
  final good = [for (var ball = 0; ball < puzzle.total; ball++) if ((suspects.heavy | suspects.light) & (1 << ball) == 0) ball];
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

// ---------- 两个假球的求解器 ----------
// 局面是还可能的球对的位集（偏重、偏轻只是左右结果互换，分不分得清一样，所以按偏重算）。对换两个球后位集不变的球可以互换，归成一类，
// 称法只看每类各放几个（同一个假球时的 u、h、l、g 就是这样的类）；确定是真的球（不在任何还可能的球对里）只补在少的一边，镜像只留一种。
typedef _PairMove = ({int left, int right});

// 对换 first、second 两个球后的球对位集。
int _pairSwap(int balls, int mask, int first, int second) {
  int image(int ball) => ball == first ? second : ball == second ? first : ball;
  var swapped = 0;
  for (final (index, (one, other)) in balancePairs(balls).indexed) {
    if (mask & (1 << index) == 0) continue;
    final (low, high) = (math.min(image(one), image(other)), math.max(image(one), image(other)));
    swapped |= 1 << balancePairIndex(balls, low, high);
  }
  return swapped;
}

List<_PairMove> _pairMoves(int balls, int mask) {
  var involved = 0;
  for (final (index, (first, second)) in balancePairs(balls).indexed) {
    if (mask & (1 << index) != 0) involved |= (1 << first) | (1 << second);
  }
  final classes = <List<int>>[];
  for (final ball in balanceMembers(involved)) {
    final home = classes.where((group) => _pairSwap(balls, mask, group.first, ball) == mask).firstOrNull;
    if (home == null) {
      classes.add([ball]);
    } else {
      home.add(ball);
    }
  }
  final good = [for (var ball = 0; ball < balls; ball++) if (involved & (1 << ball) == 0) ball];
  final moves = <_PairMove>[];
  final lefts = <int>[], rights = <int>[];
  void place(int depth) {
    if (depth < classes.length) {
      for (var onLeft = 0; onLeft <= classes[depth].length; onLeft++) {
        for (var onRight = 0; onLeft + onRight <= classes[depth].length; onRight++) {
          lefts.add(onLeft);
          rights.add(onRight);
          place(depth + 1);
          lefts.removeLast();
          rights.removeLast();
        }
      }
      return;
    }
    final (sizeLeft, sizeRight) = (lefts.fold(0, (sum, count) => sum + count), rights.fold(0, (sum, count) => sum + count));
    if (sizeLeft + sizeRight == 0) return;
    final goodLeft = math.max(0, sizeRight - sizeLeft), goodRight = math.max(0, sizeLeft - sizeRight);
    if (goodLeft + goodRight > good.length) return;
    final mirrored = [for (final (index, count) in lefts.indexed) count - rights[index], goodLeft - goodRight].firstWhere((difference) => difference != 0, orElse: () => 0);
    if (mirrored < 0) return;
    var left = 0, right = 0;
    for (final (index, group) in classes.indexed) {
      left |= balanceMask(group.take(lefts[index]));
      right |= balanceMask(group.skip(lefts[index]).take(rights[index]));
    }
    left |= balanceMask(good.take(goodLeft));
    right |= balanceMask(good.skip(goodLeft).take(goodRight));
    moves.add((left: left, right: right));
  }

  place(0);
  return moves;
}

final _pairMemo = <(int, int, int), bool>{};

bool _pairSolvable(int balls, int mask, int rounds) {
  final count = balanceBits(mask);
  if (count <= 1) return true;
  if (rounds == 0 || count > math.pow(3, rounds)) return false;
  return _pairMemo[(balls, mask, rounds)] ??= _pairMoves(balls, mask).any((move) => _pairWinning(balls, mask, move, rounds));
}

bool _pairWinning(int balls, int mask, _PairMove move, int rounds) =>
    _pairSplit(balls, mask, move.left, move.right).every((next) => next == 0 || _pairSolvable(balls, next, rounds - 1));

final _pairTreeMemo = <(int, int, int), double>{};

// 同 _treeBits 的口径。
double _pairTreeBits(int balls, int mask, int rounds) {
  if (balanceBits(mask) <= 1) return 0;
  final key = (balls, mask, rounds);
  if (_pairTreeMemo[key] case final bits?) return bits;
  final moves = _pairMoves(balls, mask);
  final good = [for (final move in moves) if (_pairWinning(balls, mask, move, rounds)) move];
  var below = 0.0;
  for (final move in good) {
    for (final next in _pairSplit(balls, mask, move.left, move.right)) {
      if (next != 0) below += _pairTreeBits(balls, next, rounds - 1);
    }
  }
  return _pairTreeMemo[key] = math.log(moves.length / good.length) / math.ln2 + below / good.length;
}

// ---------- 对外的求解 ----------

// rounds 次之内一定找得出（不管秤怎么答）。
bool balanceSolvableIn(BalancePuzzle puzzle, int rounds) => _solvableFrom(puzzle, balanceStart(puzzle), rounds);

// 这道题在限定次数内一定找得出。
bool balanceSolvable(BalancePuzzle puzzle) => balanceSolvableIn(puzzle, puzzle.weighings);

// 上限是紧的：限定次数内找得出，少称一次就不一定。
bool balanceTight(BalancePuzzle puzzle) => balanceSolvable(puzzle) && !balanceSolvableIn(puzzle, puzzle.weighings - 1);

// 参考解：每一步取第一个「不管秤怎么答都还来得及」的称法（具体放哪几个球按编号从小取），秤按规则回答，最后指认剩下的那一个（一对）。
// 题目解不开返回 null。
BalanceAnswer? balanceSolve(BalancePuzzle puzzle) {
  if (!balanceSolvable(puzzle)) return null;
  var suspects = balanceStart(puzzle);
  final weighings = <BalanceWeighing>[];
  for (var index = 0; index < puzzle.weighings && !balanceDone(puzzle, suspects); index++) {
    final rounds = puzzle.weighings - index;
    final BalanceWeighing weighing;
    if (puzzle.paired) {
      final move = _pairMoves(puzzle.balls, suspects.pairs).firstWhere((move) => _pairWinning(puzzle.balls, suspects.pairs, move, rounds));
      weighing = BalanceWeighing(balanceMembers(move.left), balanceMembers(move.right));
    } else {
      final state = _stateOf(puzzle, suspects);
      weighing = _place(puzzle, suspects, _moves(state).firstWhere((move) => _winning(state, move, rounds, puzzle.direction)));
    }
    weighings.add(weighing);
    final (left, right) = (balanceMask(weighing.left), balanceMask(weighing.right));
    suspects = balanceSplit(puzzle, suspects, left, right)[balanceRespond(puzzle, suspects, left, right, index).index];
  }
  if (puzzle.paired) {
    final (first, second) = balancePairs(puzzle.balls)[balanceMembers(suspects.pairs).single];
    return BalanceAnswer(weighings, [first, second]);
  }
  return BalanceAnswer(weighings, [balanceMembers(suspects.heavy | suspects.light).first], puzzle.direction ? suspects.heavy != 0 : null);
}

// 整道题的策略树选择量（比特），难易分由它换算。
double balanceTreeBits(BalancePuzzle puzzle) => puzzle.paired
    ? _pairTreeBits(puzzle.balls, balanceStart(puzzle).pairs, puzzle.weighings)
    : _treeBits(_stateOf(puzzle, balanceStart(puzzle)), puzzle.weighings, puzzle.direction);

// 档内的一种题型：可疑的球几个、称几次、是否已知轻重（已知时出题再随机定偏重或偏轻）、要不要说轻重、标准球几个、假球几个。
typedef BalancePlan = ({int balls, int weighings, bool known, bool direction, int standards, int fakes});

BalancePlan _plan(int balls, int weighings, {bool known = false, bool direction = false, int standards = 0, int fakes = 1}) =>
    (balls: balls, weighings: weighings, known: known, direction: direction, standards: standards, fakes: fakes);

class BalanceRules extends PuzzleRules<BalancePuzzle, BalanceAnswer> {
  const BalanceRules();

  // 第 2 版题面（11-17 深改）：加了偏哪边、标准球与假球个数，答案的指认改成球的列表。
  @override
  int get puzzleVersion => 2;

  // 挑战里的特性（[人工决策-2026-11-16 17:26:21] 见 puzzle_rules.dart 的 PuzzleRules.fragment）。
  // 碎片用题面定的称几次：秤不预定假球，没有固定的「不同的那个球」（每道题都正好够用，也就是最少要称几次）。
  @override
  int? fragment(BalancePuzzle puzzle, BalanceAnswer solution) => puzzle.weighings;

  // 每档的题型（出题时等概率挑一种，已知轻重的再等概率定偏重或偏轻），都核对过上限是紧的、难易分落在这一档的两级里（测试守护）。
  // 题型按经典变体递进：入门只有已知轻重；简单起不知轻重、标准球与两个假球；困难是 11 个球的各种变体、12 个只需找出、7 个里两个假球、16 个称 4 次；
  // 专家是经典的 12 个球说轻重与 13、14 个球（理论上限，Dyson）。
  static final pools = <PuzzleTier, List<BalancePlan>>{
    PuzzleTier.entry: [
      _plan(6, 2, known: true),
      _plan(7, 2, known: true),
      _plan(8, 2, known: true),
      _plan(9, 2, known: true),
      _plan(10, 3, known: true),
      _plan(11, 3, known: true),
      _plan(12, 3, known: true),
    ],
    PuzzleTier.easy: [
      _plan(14, 3, known: true),
      _plan(16, 3, known: true),
      _plan(8, 3),
      _plan(9, 3),
      _plan(8, 3, standards: 1),
      _plan(8, 3, direction: true),
      _plan(8, 3, direction: true, standards: 1),
      _plan(6, 3, known: true, fakes: 2),
      _plan(13, 4, direction: true),
    ],
    // [人工决策-2026-11-15 10:54:57] 普通档改为 10 个球（用户选定）：按预计用时标尺量，12 个球比简单档长约 3 倍（95 秒到 303 秒），10 个球是 120 秒。
    // 11-17 深改后普通档仍是 10 个可疑的球，题型在只需找出、说轻重、有无标准球四种里随机。
    PuzzleTier.normal: [
      _plan(10, 3),
      _plan(10, 3, standards: 1),
      _plan(10, 3, direction: true),
      _plan(10, 3, direction: true, standards: 1),
    ],
    PuzzleTier.hard: [
      _plan(11, 3, standards: 1),
      _plan(12, 3),
      _plan(11, 3, direction: true),
      _plan(11, 3, direction: true, standards: 1),
      _plan(16, 4),
      _plan(16, 4, direction: true),
      _plan(7, 3, known: true, fakes: 2),
    ],
    PuzzleTier.expert: [
      _plan(12, 3, direction: true),
      _plan(13, 3),
      _plan(14, 3, standards: 1),
      _plan(12, 3, direction: true, standards: 1),
      _plan(13, 3, direction: true, standards: 1),
    ],
  };

  // 出题：按种子挑这一档的题型与偏哪边，再定平局时秤怎么答（第一次称就有平局，走到哪一支、最后是哪个球都跟着变）；出题前核对上限是紧的。
  @override
  PuzzleDraw<BalancePuzzle, BalanceAnswer> generate(int seed, PuzzleTier tier) {
    final random = PuzzleRandom(seed);
    final plans = pools[tier]!;
    final plan = plans[random.nextInt(plans.length)];
    final light = random.nextInt(2) == 1;
    final puzzle = BalancePuzzle(
      balls: plan.balls,
      weighings: plan.weighings,
      weight: !plan.known ? BalanceWeight.unknown : light ? BalanceWeight.light : BalanceWeight.heavy,
      direction: plan.direction,
      standards: plan.standards,
      fakes: plan.fakes,
      seed: random.nextUint32(),
    );
    final solution = balanceTight(puzzle) ? balanceSolve(puzzle) : null;
    if (solution == null) throw StateError('天平称球 ${tier.name} 档的题型 $plan 不是正好 ${plan.weighings} 次');
    return PuzzleDraw(puzzle, solution);
  }

  @override
  bool solved(BalancePuzzle puzzle, BalanceAnswer answer) {
    if ((answer.heavy != null) != puzzle.direction) return false;
    final replay = balanceReplay(puzzle, answer.weighings);
    return replay != null && balanceVerdict(puzzle, replay.suspects, answer.balls, answer.heavy) == BalanceVerdict.solved;
  }

  // 难易分口径：整棵策略树的选择量（balanceTreeBits）从 3.2 比特起每 2.5 比特一级，取整夹在 1–10。题型由档里挑、种子只定平局，所以同一题型同分。
  // 实测（比特 → 分）：入门 3.8–9.0 → 1–2；简单 10.1–13.7 → 3–4；普通 10 个 15.9–18.0 → 5–6；困难 19.8–23.5 → 7–8（两个假球 7 个称 3 次 22.3 → 8）；
  // 专家经典 12 个说轻重 24.9 → 9、13 个只需找出 26.8 → 9，到理论上限的 13、14 个带标准球 32.7、34.6 → 10。各档离分界都留了 0.3 比特以上。
  // 解不开的题面（出题与解码都会拦下）按 10 分算。
  // 预计用时：1 分 45 秒、每高一级乘 1.24（各档多数题型的分是入门 1、简单 3、普通 5、困难 7、专家 9，约 45、70、105、165、250 秒），按常见的人工解题速度估。
  @override
  int expectedSeconds(BalancePuzzle puzzle) => puzzlePace(complexity(puzzle), base: 45, growth: 1.24);

  @override
  int complexity(BalancePuzzle puzzle) {
    if (!balanceSolvable(puzzle)) return 10;
    return ((balanceTreeBits(puzzle) - 3.2) / 2.5).round().clamp(1, 10);
  }

  @override
  Object encodePuzzle(BalancePuzzle puzzle) => {
    'balls': puzzle.balls,
    'standards': puzzle.standards,
    'fakes': puzzle.fakes,
    'weight': puzzle.weight.name,
    'direction': puzzle.direction,
    'weighings': puzzle.weighings,
    'seed': puzzle.seed,
  };

  // 外部输入：各字段逐项校验；说轻重只给不知轻重的题，两个假球要已知轻重、不带标准球；桌上的球数有上限；在次数内找不出的不是题。
  @override
  BalancePuzzle decodePuzzle(Object? json) {
    final balls = puzzleInt(json, 'balls', min: balanceMinBalls, max: balanceMaxBalls);
    final standards = puzzleInt(json, 'standards', min: 0, max: balanceMaxStandards);
    final fakes = puzzleInt(json, 'fakes', min: 1, max: 2);
    final weighings = puzzleInt(json, 'weighings', min: 1, max: balanceMaxWeighings);
    final seed = puzzleInt(json, 'seed', min: 0, max: 0xFFFFFFFF);
    final (weight, direction) = (BalanceWeight.values.asNameMap()[(json as Map)['weight']], json['direction']);
    if (weight == null || direction is! bool || balls + standards > balanceMaxTotal) throw const FormatException('题目字段不合法');
    if (direction && weight != BalanceWeight.unknown) throw const FormatException('题目字段不合法');
    if (fakes == 2 && (weight == BalanceWeight.unknown || standards > 0 || balls > balanceMaxPairBalls)) throw const FormatException('题目字段不合法');
    final puzzle = BalancePuzzle(balls: balls, weighings: weighings, weight: weight, direction: direction, standards: standards, fakes: fakes, seed: seed);
    if (!balanceSolvable(puzzle)) throw const FormatException('这道题在限定次数内找不出');
    return puzzle;
  }

  // 答案编成 {'weighings': [[左盘的球, 右盘的球], …], 'balls': [指认的球], 'heavy': 偏重 true / 偏轻 false（不用说轻重的题不写）}。
  @override
  Object encodeAnswer(BalanceAnswer answer) => {
    'weighings': [
      for (final weighing in answer.weighings) [[...weighing.left], [...weighing.right]],
    ],
    'balls': [...answer.balls],
    if (answer.heavy != null) 'heavy': answer.heavy,
  };

  // 只核对结构：次数不超过上限、每次是左右两组编号、同一次里一个球不放两边也不重复，指认一到两个不重复的球；
  // 两边球数等不等、编号在不在这道题里、指认几个由 solved 按规则判。
  @override
  BalanceAnswer decodeAnswer(Object? json) {
    final raw = json is Map ? json['weighings'] : null;
    if (raw is! List || raw.length > balanceMaxWeighings) throw const FormatException('答案不合法');
    final weighings = [
      for (final item in raw)
        () {
          if (item is! List || item.length != 2) throw const FormatException('答案不合法');
          final left = puzzleInts(item[0], maxLength: balanceMaxTotal, min: 0, max: balanceMaxTotal - 1);
          final right = puzzleInts(item[1], maxLength: balanceMaxTotal, min: 0, max: balanceMaxTotal - 1);
          if ({...left, ...right}.length != left.length + right.length) throw const FormatException('答案不合法');
          return BalanceWeighing(left, right);
        }(),
    ];
    final balls = puzzleInts((json as Map)['balls'], maxLength: 2, min: 0, max: balanceMaxBalls - 1);
    if (balls.isEmpty || balls.toSet().length != balls.length) throw const FormatException('答案不合法');
    final heavy = json['heavy'];
    if (heavy != null && heavy is! bool) throw const FormatException('答案不合法');
    return BalanceAnswer(weighings, balls, heavy as bool?);
  }
}
