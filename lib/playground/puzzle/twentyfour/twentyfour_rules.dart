import 'dart:math' as math;

import 'package:superxd/playground/puzzle_rules.dart';

// 24 点：四个 1–13 的数，每个恰好用一次，算出 24。入门到普通只有加减乘除，困难、专家再加乘方与开方（题面里写明允许哪些运算）。
// 一局按「合并」走：每步挑两张卡和一个二元运算，两张合成一张；开方是一元的，只改一张卡的值。合到只剩一张、等于 24 就解开。
// 运算一律用有理数精确算（分子分母都是整数），不用浮点：8 ÷ 3 就是 8/3，再乘 3 正好回到 8。
// [人工决策-2026-11-13 15:35:06] 用户选定：中间结果允许负数；困难、专家两档加乘方与开方（入门到普通保持经典四则），专家档的题必须用到乘方、开方或分数才能解（原来只靠分数，1–13 里只有 16 组会重复）。

// 每一步的结果（约分后）分子、分母的绝对值都不超过它，超了不让合：乘方会把数变得很大，卡片上也写不下。
// 经典四则三步之内最大 13^4，碰不到这条。
const twentyFourLimit = 1000000;
// 乘方的指数：必须是整数，绝对值不超过它（底至少是 2 时结果上限已经管住了，这条再管住底是 ±1 的情形）。
const twentyFourMaxExponent = 10;
// 一局最多几步（外部输入的上限）：三步二元合并，加上开方。开方要换值（√0、√1 不让开），1–13 里只有 4、9 开得了一次，
// 合出来的数在上限内最多连开四次（2^16 = 65536 → 256 → 16 → 4 → 2），所以合规的答案最多 3 + 4 + 3 × 4 = 19 步。
const twentyFourMaxSteps = 19;

const twentyFourCards = 4;
const twentyFourMin = 1;
const twentyFourMax = 13;

int? _squareRoot(int value) {
  final root = math.sqrt(value).round();
  return root * root == value ? root : null;
}

// 乘方的分子分母（约到最简）：指数要是整数、绝对值不超过 twentyFourMaxExponent，0 的 0 次与负数次方不行，结果超界不行。
// 出题求解与重放判定共用这一处，口径一致。
(int, int)? _powerParts(int numerator, int denominator, int exponentNumerator, int exponentDenominator) {
  if (exponentNumerator % exponentDenominator != 0) return null;
  final times = exponentNumerator ~/ exponentDenominator;
  if (times.abs() > twentyFourMaxExponent || (numerator == 0 && times <= 0)) return null;  final divisor = numerator.gcd(denominator) * (denominator < 0 ? -1 : 1);
  var (base, over) = (numerator ~/ divisor, denominator ~/ divisor);
  // 负数次方：倒过来再乘正数次（分母保持为正）。
  if (times < 0) (base, over) = (over * base.sign, base.abs());
  var (top, bottom) = (1, 1);
  for (var round = 0; round < times.abs(); round++) {
    top *= base;
    bottom *= over;
    if (top.abs() > twentyFourLimit || bottom > twentyFourLimit) return null;
  }
  return (top, bottom);
}

// 开方的分子分母：值要大于 0 且不是 1（√0、√1 不改变值，白走一步、求解器也会绕圈，不让开），约分后分子分母都是完全平方数才开得尽。
(int, int)? _rootParts(int numerator, int denominator) {
  if (numerator == 0 || (numerator > 0) != (denominator > 0)) return null;
  final divisor = numerator.gcd(denominator);
  final (top, bottom) = ((numerator ~/ divisor).abs(), (denominator ~/ divisor).abs());
  if (top == bottom) return null;
  final (rootTop, rootBottom) = (_squareRoot(top), _squareRoot(bottom));
  return rootTop == null || rootBottom == null ? null : (rootTop, rootBottom);
}

// 分数：分母恒为正、约到最简。
class TwentyFourValue {
  factory TwentyFourValue(int numerator, [int denominator = 1]) {
    if (denominator == 0) throw ArgumentError.value(denominator, 'denominator');
    final divisor = numerator.gcd(denominator) * (denominator < 0 ? -1 : 1);
    return TwentyFourValue._(numerator ~/ divisor, denominator ~/ divisor);
  }
  const TwentyFourValue._(this.numerator, this.denominator);

  final int numerator, denominator;

  bool get whole => denominator == 1;
  bool get bounded => numerator.abs() <= twentyFourLimit && denominator <= twentyFourLimit;

  TwentyFourValue operator +(TwentyFourValue other) => TwentyFourValue(numerator * other.denominator + other.numerator * denominator, denominator * other.denominator);
  TwentyFourValue operator -(TwentyFourValue other) => TwentyFourValue(numerator * other.denominator - other.numerator * denominator, denominator * other.denominator);
  TwentyFourValue operator *(TwentyFourValue other) => TwentyFourValue(numerator * other.numerator, denominator * other.denominator);
  // 除以零返回 null。
  TwentyFourValue? over(TwentyFourValue other) => other.numerator == 0 ? null : TwentyFourValue(numerator * other.denominator, denominator * other.numerator);

  // 乘方与开方：不合规（口径见 _powerParts、_rootParts）返回 null。
  TwentyFourValue? power(TwentyFourValue exponent) => switch (_powerParts(numerator, denominator, exponent.numerator, exponent.denominator)) {
    (final top, final bottom) => TwentyFourValue(top, bottom),
    null => null,
  };
  TwentyFourValue? root() => switch (_rootParts(numerator, denominator)) {
    (final top, final bottom) => TwentyFourValue(top, bottom),
    null => null,
  };

  @override
  bool operator ==(Object other) => other is TwentyFourValue && other.numerator == numerator && other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  // 整数写成整数，分数写成「分子/分母」（如 8/3、-1/3）。
  @override
  String toString() => whole ? '$numerator' : '$numerator/$denominator';
}

const twentyFourTarget = TwentyFourValue._(24, 1);

// 运算：code 写进题面与答案编码，发出后不改（加新运算只往后加）。减、除、乘方是「第一张 op 第二张」（乘方的第二张是指数）；
// 开方是一元的，只作用在一张卡上。
enum TwentyFourOp {
  add(0, '+'),
  subtract(1, '−'),
  multiply(2, '×'),
  divide(3, '÷'),
  power(4, '^'),
  root(5, '√');

  const TwentyFourOp(this.code, this.symbol);
  final int code;
  final String symbol;

  bool get unary => this == root;

  static TwentyFourOp? coded(int code) => values.where((op) => op.code == code).firstOrNull;

  // 二元运算：第一张 op 第二张；不合规（除以零、乘方不合规、结果超过 twentyFourLimit）返回 null。开方见 TwentyFourValue.root。
  TwentyFourValue? apply(TwentyFourValue first, TwentyFourValue second) {
    final value = switch (this) {
      TwentyFourOp.add => first + second,
      TwentyFourOp.subtract => first - second,
      TwentyFourOp.multiply => first * second,
      TwentyFourOp.divide => first.over(second),
      TwentyFourOp.power => first.power(second),
      TwentyFourOp.root => null,
    };
    return value != null && value.bounded ? value : null;
  }
}

// 运算集合：入门到普通是经典四则，困难、专家再加乘方与开方。
const twentyFourClassic = {TwentyFourOp.add, TwentyFourOp.subtract, TwentyFourOp.multiply, TwentyFourOp.divide};
const twentyFourExtended = {...twentyFourClassic, TwentyFourOp.power, TwentyFourOp.root};

// 一步。下标规则：四个位置按题面的顺序编 0–3（第 i 个数开局在第 i 个位置）。
// 二元运算：first 与 second 是两个不同的位置，结果放进第二张（second）的位置，第一张的位置空出来，之后不能再用；
// 开方：first 与 second 是同一个位置（答案里写成 [卡, 5, 同一张卡]），结果留在原位置。
class TwentyFourStep {
  const TwentyFourStep(this.first, this.op, this.second);
  final int first, second;
  final TwentyFourOp op;
}

// 题面：四个数（按出题时的顺序摆在四个位置上）与允许的运算（服务器判题按它核对每一步）。
class TwentyFourPuzzle {
  const TwentyFourPuzzle(this.numbers, [this.ops = twentyFourClassic]);
  final List<int> numbers;
  final Set<TwentyFourOp> ops;
}

// 开局的四个位置。
List<TwentyFourValue?> twentyFourStart(TwentyFourPuzzle puzzle) => [for (final number in puzzle.numbers) TwentyFourValue(number)];

// 这一步算出来的数；不合规（位置越界、位置已经空了、二元运算用了同一个位置、开方用了两个位置、运算本身不合规）返回 null。不改 slots。
// 运算是否是题面允许的由 twentyFourReplay 核对。
TwentyFourValue? twentyFourMerge(List<TwentyFourValue?> slots, TwentyFourStep step) {
  final (first, second) = (step.first, step.second);
  if (first < 0 || second < 0 || first >= slots.length || second >= slots.length) return null;
  final (left, right) = (slots[first], slots[second]);
  if (left == null || right == null || (first == second) != step.op.unary) return null;
  return step.op.unary ? left.root() : step.op.apply(left, right);
}

// 从开局依次走，返回走完的四个位置；有一步不合规或用了题面不允许的运算返回 null。
List<TwentyFourValue?>? twentyFourReplay(TwentyFourPuzzle puzzle, Iterable<TwentyFourStep> steps) {
  final slots = twentyFourStart(puzzle);
  for (final step in steps) {
    if (!puzzle.ops.contains(step.op)) return null;
    final value = twentyFourMerge(slots, step);
    if (value == null) return null;
    slots[step.first] = null;
    slots[step.second] = value;
  }
  return slots;
}

// 求解的结果：solutions 是去掉等价写法后的解法数（口径见 _canonical），没有解是 0；
// plain：有只用加减乘的解法（÷1、指数等于 1 的乘方当成乘法，口径见 _canonical）；whole：有只用加减乘除、过程中都是整数的解法（经典四则不经过分数）；
// sample 是一份参考解（有 whole 的解法时取它，同样的取最先找到的），没有解是 null。
typedef TwentyFourAnalysis = ({int solutions, bool plain, bool whole, List<TwentyFourStep>? sample});

// 算式树：只在求解时用，合到 24 的才化成规范写法比对。值存成分子、分母，在上限内就不约分（枚举时省掉求最大公约数；
// 分母可能是负的）；两数都在上限内，乘加一步最多 2 × 10^12，远不到 64 位的上限。
class _Term {
  _Term.leaf(this.number) : numerator = number, denominator = 1, op = null, left = null, right = null;
  _Term(TwentyFourOp this.op, _Term this.left, this.right, this.numerator, this.denominator) : number = 0;
  final int numerator, denominator;
  final TwentyFourOp? op;
  // 开方只有 left。
  final _Term? left, right;
  final int number;

  int get sign => numerator == 0 ? 0 : (numerator > 0) == (denominator > 0) ? 1 : -1;
  bool get whole => numerator % denominator == 0;
  // 指数等于 1 的乘方（a^1、a^(1 × 1)、a^(3 − 2)……）：都等于底本身，同乘以那个指数（a × 1、a × (3 − 2)）。
  bool get timesOne => op == TwentyFourOp.power && right!.numerator == right!.denominator;
}

// 没约分的分子分母：都在上限内直接用；超了先约分再看，约完还超就不让合（同 TwentyFourValue.bounded：约分后才算超界）。
(int, int)? _fit(int numerator, int denominator) {
  if (numerator.abs() <= twentyFourLimit && denominator.abs() <= twentyFourLimit) return (numerator, denominator);
  final divisor = numerator.gcd(denominator);
  final (top, bottom) = (numerator ~/ divisor, denominator ~/ divisor);
  return top.abs() <= twentyFourLimit && bottom.abs() <= twentyFourLimit ? (top, bottom) : null;
}

// 两棵算式合一步；不合规返回 null。
_Term? _join(TwentyFourOp op, _Term x, _Term y) {
  final (xn, xd, yn, yd) = (x.numerator, x.denominator, y.numerator, y.denominator);
  final raw = switch (op) {
    TwentyFourOp.add => (xn * yd + yn * xd, xd * yd),
    TwentyFourOp.subtract => (xn * yd - yn * xd, xd * yd),
    TwentyFourOp.multiply => (xn * yn, xd * yd),
    TwentyFourOp.divide => yn == 0 ? null : (xn * yd, xd * yn),
    TwentyFourOp.power => _powerParts(xn, xd, yn, yd),
    TwentyFourOp.root => null,
  };
  final fitted = raw == null ? null : _fit(raw.$1, raw.$2);
  return fitted == null ? null : _Term(op, x, y, fitted.$1, fitted.$2);
}

_Term? _root(_Term term) => switch (_rootParts(term.numerator, term.denominator)) {
  (final top, final bottom) => _Term(TwentyFourOp.root, term, null, top, bottom),
  null => null,
};

// 规范写法（判两种解法是不是同一种）：
// - 加减连在一起的拍平成一串带正负号的项、乘除连在一起的拍平成分子与分母两组因子（交换律、结合律、a − (b − c) = a − b + c、
//   a ÷ (b ÷ c) = a × c ÷ b 都并到一起），组内按写法排序；
// - ÷1 当成 ×1；指数等于 1 的乘方当成乘以那个指数（a^1 同 a × 1、a^(3 − 2) 同 a × (3 − 2)）；
// - 负数提到外面：一串和的值是负的就整串变号、符号交给上一层（(3 − 8) × (2 − 9) 与 (8 − 3) × (9 − 2) 算同一种），值是 0 的取两种写法里排前的；
// - 其余的乘方与开方各当成一个整体（原子项）：乘方写成「底^带符号的指数」，底是负的、指数是偶数时符号消掉；开方写成「√里面」。
//   不再展开 (a × b)^2 = a^2 × b^2 这类恒等式。
// 返回（符号, 写法, 有没有用到除法, 有没有用到乘方或开方）。
(int, String, bool, bool) _canonical(_Term term) {
  final op = term.op;
  if (op == null) return (1, '${term.number}', false, false);
  if (op == TwentyFourOp.root) {
    final (_, text, division, _) = _canonical(term.left!);
    return (1, 'R($text)', division, true);
  }
  if (op == TwentyFourOp.power && !term.timesOne) {
    final (baseSign, base, baseDivision, _) = _canonical(term.left!);
    final (exponentSign, exponent, exponentDivision, _) = _canonical(term.right!);
    final odd = (term.right!.numerator ~/ term.right!.denominator).isOdd;
    return (baseSign < 0 && odd ? -1 : 1, 'W($base^${exponentSign < 0 ? '-' : '+'}$exponent)', baseDivision || exponentDivision, true);
  }
  var division = false, advanced = false;
  if (op == TwentyFourOp.add || op == TwentyFourOp.subtract) {
    final terms = <(int, _Term)>[];
    void collect(_Term part, int sign) {
      if (part.op == TwentyFourOp.add) {
        collect(part.left!, sign);
        collect(part.right!, sign);
      } else if (part.op == TwentyFourOp.subtract) {
        collect(part.left!, sign);
        collect(part.right!, -sign);
      } else {
        terms.add((sign, part));
      }
    }

    collect(term, 1);
    final signed = [
      for (final (sign, part) in terms)
        () {
          final (partSign, text, partDivision, partAdvanced) = _canonical(part);
          division |= partDivision;
          advanced |= partAdvanced;
          return (sign * partSign, text);
        }(),
    ];
    String write(int flip) => 'S(${([for (final (sign, text) in signed) '${sign * flip > 0 ? '+' : '-'}$text']..sort()).join(',')})';
    if (term.sign < 0) return (-1, write(-1), division, advanced);
    if (term.sign > 0) return (1, write(1), division, advanced);
    final (kept, flipped) = (write(1), write(-1));
    return (1, kept.compareTo(flipped) <= 0 ? kept : flipped, division, advanced);
  }
  final above = <String>[], below = <String>[];
  var sign = 1;
  void collect(_Term part, bool up) {
    if (part.op == TwentyFourOp.multiply || part.timesOne) {
      collect(part.left!, up);
      collect(part.right!, up);
    } else if (part.op == TwentyFourOp.divide) {
      collect(part.left!, up);
      collect(part.right!, !up);
    } else {
      final (partSign, text, partDivision, partAdvanced) = _canonical(part);
      sign *= partSign;
      division |= partDivision;
      advanced |= partAdvanced;
      (up || text == '1' ? above : below).add(text);
    }
  }

  collect(term, true);
  return (sign, 'P(${(above..sort()).join('*')}/${(below..sort()).join('*')})', division || below.isNotEmpty, advanced);
}

// 一对卡的合法：加、乘不分先后，减、除、乘方两个方向（经典四则的六种在前，顺序不动，入门到普通出的题与参考解不变）。
// swap 为真时是「第二张 op 第一张」，结果放进第一张的位置。
const _ways = [
  (false, TwentyFourOp.add),
  (false, TwentyFourOp.multiply),
  (false, TwentyFourOp.subtract),
  (true, TwentyFourOp.subtract),
  (false, TwentyFourOp.divide),
  (true, TwentyFourOp.divide),
  (false, TwentyFourOp.power),
  (true, TwentyFourOp.power),
];

// 枚举全部走法：每一步在剩下的卡里挑两张（不分先后）与题面允许的二元运算合成一张；允许开方时，每张卡（开局的数与每次合出来的数）
// 一出现就试着不开、开一次、开两次……（开方挪到卡刚出现时做，同一棵算式不重复数；√0、√1 不让开，所以每次开都换值，链是有限的）。
// 经典四则时 4 张 6 × 6、3 张 3 × 6、2 张 6，一共 3888 种走法。
// 每合到 24 调一次 reached（最后那棵算式、这一走法的步骤、过程中出没出现分数），它返回 true 就不再往下找；
// wholeOnly 时一出现分数就不往下走（只找不经过分数的走法）。
void _search(List<int> numbers, Set<TwentyFourOp> ops, bool Function(_Term last, List<TwentyFourStep> steps, bool fraction) reached, {bool wholeOnly = false}) {
  final ways = [for (final way in _ways) if (ops.contains(way.$2)) way];
  final roots = ops.contains(TwentyFourOp.root);
  final slots = <_Term?>[for (final number in numbers) _Term.leaf(number)];
  final steps = <TwentyFourStep>[];
  var stopped = false;

  // 把 term 放进 slot 往下走（next），能开方就开了再走一次。
  void settle(int slot, _Term term, bool fraction, void Function(bool fraction) next) {
    var (current, path, rooted) = (term, fraction || !term.whole, 0);
    while (true) {
      slots[slot] = current;
      next(path);
      final deeper = roots && !stopped ? _root(current) : null;
      if (deeper == null || (wholeOnly && !deeper.whole)) break;
      steps.add(TwentyFourStep(slot, TwentyFourOp.root, slot));
      (current, path, rooted) = (deeper, path || !deeper.whole, rooted + 1);
    }
    steps.length -= rooted;
  }

  void walk(int left, bool fraction) {
    if (left == 1) {
      final last = slots.nonNulls.single;
      if (last.numerator == twentyFourTarget.numerator * last.denominator) stopped = reached(last, steps, fraction);
      return;
    }
    for (var first = 0; first < slots.length; first++) {
      for (var second = first + 1; second < slots.length; second++) {
        if (slots[first] == null || slots[second] == null) continue;
        for (final (swap, op) in ways) {
          final (from, into) = swap ? (second, first) : (first, second);
          final (x, y) = (slots[from]!, slots[into]!);
          final joined = _join(op, x, y);
          if (joined == null || (wholeOnly && !joined.whole)) continue;
          slots[from] = null;
          steps.add(TwentyFourStep(from, op, into));
          settle(into, joined, fraction, (path) => walk(left - 1, path));
          steps.removeLast();
          slots[from] = x;
          slots[into] = y;
          if (stopped) return;
        }
      }
    }
  }

  void start(int index, bool fraction) {
    if (index == numbers.length) return walk(numbers.length, fraction);
    settle(index, _Term.leaf(numbers[index]), fraction, (path) => start(index + 1, path));
  }

  start(0, false);
}

// 经典四则有没有不经过分数就合到 24 的走法（找到一种就停）。
bool _wholeReachable(List<int> numbers) {
  var reached = false;
  _search(numbers, twentyFourClassic, (last, steps, fraction) => reached = true, wholeOnly: true);
  return reached;
}

// 用这些运算找一种解法（找到就停），没有返回 null。
List<TwentyFourStep>? _firstSolution(List<int> numbers, Set<TwentyFourOp> ops) {
  List<TwentyFourStep>? found;
  _search(numbers, ops, (last, steps, fraction) {
    found = List.unmodifiable(steps);
    return true;
  });
  return found;
}

// 求解：枚举全部走法，合到 24 的化成规范写法去重。
TwentyFourAnalysis twentyFourAnalyze(List<int> numbers, Set<TwentyFourOp> ops) {
  // 规范写法 → 这种解法只用加减乘吗、有没有经典四则不经过分数的走法。
  final found = <String, ({bool plain, bool whole})>{};
  List<TwentyFourStep>? sample;
  var sampleWhole = false;
  _search(numbers, ops, (last, steps, fraction) {
    final (_, text, division, advanced) = _canonical(last);
    final whole = !advanced && !fraction;
    found[text] = (plain: !division && !advanced, whole: whole || (found[text]?.whole ?? false));
    if (sample == null || (whole && !sampleWhole)) {
      sample = List.unmodifiable(steps);
      sampleWhole = whole;
    }
    return false;
  });
  final ways = found.values;
  return (solutions: found.length, plain: ways.any((way) => way.plain), whole: ways.any((way) => way.whole), sample: sample);
}

// 难度分（1–10）口径：先看非用不可的算法，再看解法多少（去掉等价写法后的解法数，口径见 _canonical，按题面允许的运算数）：
// - 经典四则不经过分数解不开（必须经过分数，或必须用乘方、开方）：9，只有一种解法 10；
// - 有经典四则不经过分数的解法、但每种解法都要用除法、乘方或开方：7，只有一种解法 8；
// - 只用加减乘就能解的，按解法数：8 种以上 1、5–7 种 2、4 种 3、3 种 4、2 种 5、只有 1 种 6。
// 只有经典四则时就是原来的口径（入门到普通出的题不变）。各档按分数段出题（_scores），所以同档最多差 1 分、档与档之间不重叠地往上走。
// 1–13 的 1820 组数（不计顺序），经典四则有解的 1362 组：1–2 分 192 组（1–9 里 63 组）、3–4 分 357 组（1–10 里 170 组）、
// 5–6 分 614 组、7–8 分 183 组（加上乘方与开方后 7 分 154 组、8 分 29 组）；9–10 分加上乘方与开方有 358 组（9 分 285、10 分 73，
// 原来只靠分数只有 3 3 8 8、1 5 5 5 这类 16 组），仍算不出的 116 组。1^b、a^0 这类白吃一张卡的乘方照样算数（禁掉只少 2 组，不值得多一条规矩）。
// 没有解的题面不会出、也解码不进来，按 10 分算。
int twentyFourScore(TwentyFourAnalysis analysis) {
  final solutions = analysis.solutions;
  if (solutions == 0) return 10;
  if (!analysis.whole) return solutions == 1 ? 10 : 9;
  if (!analysis.plain) return solutions == 1 ? 8 : 7;
  return switch (solutions) {
    >= 8 => 1,
    >= 5 => 2,
    4 => 3,
    3 => 4,
    2 => 5,
    _ => 6,
  };
}

class TwentyFourRules extends PuzzleRules<TwentyFourPuzzle, List<TwentyFourStep>> {
  const TwentyFourRules();

  // 每档的数从哪个区间里抽、允许哪些运算、难度分落在哪一段。入门、简单的数小，心算轻松；普通起用到 13；困难起加乘方与开方。
  static const _ranges = {PuzzleTier.entry: (1, 9), PuzzleTier.easy: (1, 10), PuzzleTier.normal: (1, 13), PuzzleTier.hard: (1, 13), PuzzleTier.expert: (1, 13)};
  static const _ops = {
    PuzzleTier.entry: twentyFourClassic,
    PuzzleTier.easy: twentyFourClassic,
    PuzzleTier.normal: twentyFourClassic,
    PuzzleTier.hard: twentyFourExtended,
    PuzzleTier.expert: twentyFourExtended,
  };
  static const _scores = {PuzzleTier.entry: (1, 2), PuzzleTier.easy: (3, 4), PuzzleTier.normal: (5, 6), PuzzleTier.hard: (7, 8), PuzzleTier.expert: (9, 10)};

  // 出题：在这一档的区间里随机抽四个数，难度分落在这一档的分数段、确认有解才用，否则重抽。
  // - 专家档：经典四则不经过分数就能解的不要（先用找到就停的求解筛，大多数组合几步就找到），剩下的用全部运算找一种解法，找得到就用；
  // - 其余各档：分数段只取决于「只用加减乘能不能解、经典四则有没有不经过分数的解法」与解法数，前两条与乘方、开方无关，
  //   困难档按经典四则求解定档（乘方、开方是多给的办法，解法数在难度分里另算，仍落在 7–8 分）。
  @override
  PuzzleDraw<TwentyFourPuzzle, List<TwentyFourStep>> generate(int seed, PuzzleTier tier) {
    final (low, high) = _ranges[tier]!;
    final (lowest, highest) = _scores[tier]!;
    final ops = _ops[tier]!;
    final random = PuzzleRandom(seed);
    while (true) {
      final numbers = List<int>.unmodifiable([for (var card = 0; card < twentyFourCards; card++) low + random.nextInt(high - low + 1)]);
      if (tier == PuzzleTier.expert) {
        if (_wholeReachable(numbers)) continue;
        final sample = _firstSolution(numbers, ops);
        if (sample == null) continue;
        return PuzzleDraw(TwentyFourPuzzle(numbers, ops), sample);
      }
      final analysis = twentyFourAnalyze(numbers, twentyFourClassic);
      final score = twentyFourScore(analysis);
      if (analysis.sample == null || score < lowest || score > highest) continue;
      return PuzzleDraw(TwentyFourPuzzle(numbers, ops), analysis.sample!);
    }
  }

  // 按规则重放：每步合规、运算是题面允许的、不超过 twentyFourMaxSteps 步，最后只剩一张而且是 24。不和参考解比。
  @override
  bool solved(TwentyFourPuzzle puzzle, List<TwentyFourStep> answer) {
    if (answer.length > twentyFourMaxSteps) return false;
    final left = twentyFourReplay(puzzle, answer)?.nonNulls.toList();
    return left != null && left.length == 1 && left.single == twentyFourTarget;
  }

  @override
  int difficulty(TwentyFourPuzzle puzzle) => twentyFourScore(twentyFourAnalyze(puzzle.numbers, puzzle.ops));

  // 题面编成 {'numbers': [四个数，按位置顺序], 'ops': [允许的运算 code，从小到大]}。
  @override
  Object encodePuzzle(TwentyFourPuzzle puzzle) => {
    'numbers': [...puzzle.numbers],
    'ops': [for (final op in TwentyFourOp.values) if (puzzle.ops.contains(op)) op.code],
  };

  // 运算集合必须含加减乘除（可另加乘方、开方），不重复；用这些运算算不出 24 的题拒收。
  @override
  TwentyFourPuzzle decodePuzzle(Object? json) {
    final numbers = puzzleInts(json is Map ? json['numbers'] : null, maxLength: twentyFourCards, min: twentyFourMin, max: twentyFourMax);
    if (numbers.length != twentyFourCards) throw const FormatException('题目要四个数');
    final codes = puzzleInts(json is Map ? json['ops'] : null, maxLength: TwentyFourOp.values.length, min: 0, max: TwentyFourOp.values.length - 1);
    final ops = {for (final code in codes) TwentyFourOp.coded(code)!};
    if (ops.length != codes.length || !ops.containsAll(twentyFourClassic)) throw const FormatException('运算集合不合法');
    if (_firstSolution(numbers, ops) == null) throw const FormatException('这四个数算不出 24');
    return TwentyFourPuzzle(List.unmodifiable(numbers), Set.unmodifiable(ops));
  }

  // 答案每步编成 [第一张的位置, 运算 code, 第二张的位置]，开方写成 [卡的位置, 5, 同一个位置]，最多 twentyFourMaxSteps 步。
  @override
  Object encodeAnswer(List<TwentyFourStep> answer) => [
    for (final step in answer) [step.first, step.op.code, step.second],
  ];

  @override
  List<TwentyFourStep> decodeAnswer(Object? json) {
    if (json is! List || json.length > twentyFourMaxSteps) throw const FormatException('答案不合法');
    return List.unmodifiable([
      for (final raw in json)
        if (puzzleInts(raw, maxLength: 3, min: 0, max: TwentyFourOp.values.length - 1) case [final first, final code, final second]
            when first < twentyFourCards && second < twentyFourCards)
          TwentyFourStep(first, TwentyFourOp.coded(code)!, second)
        else
          throw const FormatException('答案的一步不合法'),
    ]);
  }
}
