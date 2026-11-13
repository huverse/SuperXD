import 'package:superxd/playground/puzzle_rules.dart';

// 24 点：四个 1–13 的数，每个恰好用一次，用加减乘除算出 24。
// 一局按「合并」走：每步挑两张卡和一个运算，两张合成一张，三步之后剩一张，等于 24 就解开。
// 运算一律用有理数精确算（分子分母都是整数），不用浮点：8 ÷ 3 就是 8/3，再乘 3 正好回到 8。

// 分数：分母恒为正、约到最简。四个 13 以内的数算三步，分子分母都不超过 13^4，64 位整数够用。
class TwentyFourValue {
  factory TwentyFourValue(int numerator, [int denominator = 1]) {
    if (denominator == 0) throw ArgumentError.value(denominator, 'denominator');
    final divisor = numerator.gcd(denominator) * (denominator < 0 ? -1 : 1);
    return TwentyFourValue._(numerator ~/ divisor, denominator ~/ divisor);
  }
  const TwentyFourValue._(this.numerator, this.denominator);

  final int numerator, denominator;

  bool get whole => denominator == 1;

  TwentyFourValue operator +(TwentyFourValue other) => TwentyFourValue(numerator * other.denominator + other.numerator * denominator, denominator * other.denominator);
  TwentyFourValue operator -(TwentyFourValue other) => TwentyFourValue(numerator * other.denominator - other.numerator * denominator, denominator * other.denominator);
  TwentyFourValue operator *(TwentyFourValue other) => TwentyFourValue(numerator * other.numerator, denominator * other.denominator);
  // 除以零返回 null。
  TwentyFourValue? over(TwentyFourValue other) => other.numerator == 0 ? null : TwentyFourValue(numerator * other.denominator, denominator * other.numerator);

  @override
  bool operator ==(Object other) => other is TwentyFourValue && other.numerator == numerator && other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  // 整数写成整数，分数写成「分子/分母」（如 8/3、-1/3）。
  @override
  String toString() => whole ? '$numerator' : '$numerator/$denominator';
}

const twentyFourTarget = TwentyFourValue._(24, 1);

// 运算：code 写进答案编码，发出后不改。减与除是「第一张 − 第二张」「第一张 ÷ 第二张」。
enum TwentyFourOp {
  add(0, '+'),
  subtract(1, '−'),
  multiply(2, '×'),
  divide(3, '÷');

  const TwentyFourOp(this.code, this.symbol);
  final int code;
  final String symbol;

  static TwentyFourOp? coded(int code) => values.where((op) => op.code == code).firstOrNull;

  // 第一张 op 第二张；除以零返回 null。
  TwentyFourValue? apply(TwentyFourValue first, TwentyFourValue second) => switch (this) {
    TwentyFourOp.add => first + second,
    TwentyFourOp.subtract => first - second,
    TwentyFourOp.multiply => first * second,
    TwentyFourOp.divide => first.over(second),
  };
}

// 一步合并。下标规则：四个位置按题面的顺序编 0–3（第 i 个数开局在第 i 个位置）；
// 结果放进第二张（second）的位置，第一张（first）的位置空出来，之后不能再用。
class TwentyFourStep {
  const TwentyFourStep(this.first, this.op, this.second);
  final int first, second;
  final TwentyFourOp op;
}

// 题面：四个数，按出题时的顺序摆在四个位置上。
class TwentyFourPuzzle {
  const TwentyFourPuzzle(this.numbers);
  final List<int> numbers;
}

const twentyFourCards = 4;
const twentyFourMin = 1;
const twentyFourMax = 13;

// 开局的四个位置。
List<TwentyFourValue?> twentyFourStart(TwentyFourPuzzle puzzle) => [for (final number in puzzle.numbers) TwentyFourValue(number)];

// 这一步合并出来的数；不合规（位置越界、同一个位置、位置已经空了、除以零）返回 null。不改 slots。
TwentyFourValue? twentyFourMerge(List<TwentyFourValue?> slots, TwentyFourStep step) {
  final (first, second) = (step.first, step.second);
  if (first == second || first < 0 || second < 0 || first >= slots.length || second >= slots.length) return null;
  final (left, right) = (slots[first], slots[second]);
  if (left == null || right == null) return null;
  return step.op.apply(left, right);
}

// 从开局依次合并，返回合并完的四个位置；有一步不合规返回 null。
List<TwentyFourValue?>? twentyFourReplay(TwentyFourPuzzle puzzle, Iterable<TwentyFourStep> steps) {
  final slots = twentyFourStart(puzzle);
  for (final step in steps) {
    final value = twentyFourMerge(slots, step);
    if (value == null) return null;
    slots[step.second] = value;
    slots[step.first] = null;
  }
  return slots;
}

// 求解的结果：solutions 是去掉等价写法后的解法数（口径见 _canonical），没有解是 0；
// needsDivision：每种解法都要用到除法（÷1 不算）；needsFraction：每种解法都要经过非整数的中间结果（如 8/3）；
// sample 是一份参考解（有不经过分数的走法时取它，同样的取最先找到的），没有解是 null。
typedef TwentyFourAnalysis = ({int solutions, bool needsDivision, bool needsFraction, List<TwentyFourStep>? sample});

// 算式树：只在求解时用，合到 24 的才化成规范写法比对。值存成没约分的分子、分母（枚举时省掉求最大公约数；
// 分母可能是负的，三步之内分子分母都不超过 13^4 的几倍，远不到 64 位的上限）。
class _Term {
  _Term.leaf(this.number) : numerator = number, denominator = 1, op = null, left = null, right = null;
  _Term(TwentyFourOp this.op, _Term this.left, _Term this.right, this.numerator, this.denominator) : number = 0;
  final int numerator, denominator;
  final TwentyFourOp? op;
  final _Term? left, right;
  final int number;

  int get sign => numerator == 0 ? 0 : (numerator > 0) == (denominator > 0) ? 1 : -1;
}

// 两棵算式合一步；除以零返回 null。
_Term? _join(TwentyFourOp op, _Term x, _Term y) => switch (op) {
  TwentyFourOp.add => _Term(op, x, y, x.numerator * y.denominator + y.numerator * x.denominator, x.denominator * y.denominator),
  TwentyFourOp.subtract => _Term(op, x, y, x.numerator * y.denominator - y.numerator * x.denominator, x.denominator * y.denominator),
  TwentyFourOp.multiply => _Term(op, x, y, x.numerator * y.numerator, x.denominator * y.denominator),
  TwentyFourOp.divide => y.numerator == 0 ? null : _Term(op, x, y, x.numerator * y.denominator, x.denominator * y.numerator),
};

// 规范写法（判两种解法是不是同一种）：
// - 加减连在一起的拍平成一串带正负号的项、乘除连在一起的拍平成分子与分母两组因子（交换律、结合律、a − (b − c) = a − b + c、
//   a ÷ (b ÷ c) = a × c ÷ b 都并到一起），组内按写法排序；
// - ÷1 当成 ×1；
// - 负数提到外面：一串和的值是负的就整串变号、符号交给上一层（(3 − 8) × (2 − 9) 与 (8 − 3) × (9 − 2) 算同一种），值是 0 的取两种写法里排前的。
// 返回（符号, 写法, 有没有用到除法）。
(int, String, bool) _canonical(_Term term) {
  final op = term.op;
  if (op == null) return (1, '${term.number}', false);
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
    var division = false;
    final signed = [
      for (final (sign, part) in terms)
        () {
          final (partSign, text, partDivision) = _canonical(part);
          division |= partDivision;
          return (sign * partSign, text);
        }(),
    ];
    String write(int flip) => 'S(${([for (final (sign, text) in signed) '${sign * flip > 0 ? '+' : '-'}$text']..sort()).join(',')})';
    if (term.sign < 0) return (-1, write(-1), division);
    if (term.sign > 0) return (1, write(1), division);
    final (plain, flipped) = (write(1), write(-1));
    return (1, plain.compareTo(flipped) <= 0 ? plain : flipped, division);
  }
  final above = <String>[], below = <String>[];
  var sign = 1;
  var division = false;
  void collect(_Term part, bool up) {
    if (part.op == TwentyFourOp.multiply) {
      collect(part.left!, up);
      collect(part.right!, up);
    } else if (part.op == TwentyFourOp.divide) {
      collect(part.left!, up);
      collect(part.right!, !up);
    } else {
      final (partSign, text, partDivision) = _canonical(part);
      sign *= partSign;
      division |= partDivision;
      (up || text == '1' ? above : below).add(text);
    }
  }

  collect(term, true);
  return (sign, 'P(${(above..sort()).join('*')}/${(below..sort()).join('*')})', division || below.isNotEmpty);
}

// 一对卡的六种合法：加、乘不分先后，减、除两个方向。swap 为真时是「第二张 op 第一张」，结果放进第一张的位置。
const _ways = [
  (false, TwentyFourOp.add),
  (false, TwentyFourOp.multiply),
  (false, TwentyFourOp.subtract),
  (true, TwentyFourOp.subtract),
  (false, TwentyFourOp.divide),
  (true, TwentyFourOp.divide),
];

// 枚举全部合并顺序：每一步在剩下的卡里挑两张（不分先后）和六种合法，4 张时 6 × 6、3 张时 3 × 6、2 张时 6，一共 3888 种走法。
// 每合到 24 调一次 reached（最后那棵算式、这一走法的步骤、过程中出没出现分数），它返回 true 就不再往下找；
// wholeOnly 时一出现分数就不往下走（只找不经过分数的走法）。
void _search(List<int> numbers, bool Function(_Term last, List<TwentyFourStep> steps, bool fraction) reached, {bool wholeOnly = false}) {
  final slots = <_Term?>[for (final number in numbers) _Term.leaf(number)];
  final steps = <TwentyFourStep>[];
  var stopped = false;
  void walk(int left, bool fraction) {
    if (left == 1) {
      final last = slots.nonNulls.single;
      if (last.numerator == twentyFourTarget.numerator * last.denominator) stopped = reached(last, steps, fraction);
      return;
    }
    for (var first = 0; first < slots.length; first++) {
      for (var second = first + 1; second < slots.length; second++) {
        if (slots[first] == null || slots[second] == null) continue;
        for (final (swap, op) in _ways) {
          final (from, into) = swap ? (second, first) : (first, second);
          final (x, y) = (slots[from]!, slots[into]!);
          final joined = _join(op, x, y);
          if (joined == null) continue;
          final whole = joined.numerator % joined.denominator == 0;
          if (wholeOnly && !whole) continue;
          slots[into] = joined;
          slots[from] = null;
          steps.add(TwentyFourStep(from, op, into));
          walk(left - 1, fraction || !whole);
          steps.removeLast();
          slots[from] = x;
          slots[into] = y;
          if (stopped) return;
        }
      }
    }
  }

  walk(numbers.length, false);
}

// 有没有不经过分数就合到 24 的走法（找到一种就停）。
bool _wholeReachable(List<int> numbers) {
  var reached = false;
  _search(numbers, (last, steps, fraction) => reached = true, wholeOnly: true);
  return reached;
}

// 求解：枚举全部走法，合到 24 的化成规范写法去重。
TwentyFourAnalysis twentyFourAnalyze(List<int> numbers) {
  // 规范写法 → 有没有不经过分数的走法、有没有用到除法。
  final found = <String, ({bool whole, bool division})>{};
  List<TwentyFourStep>? sample;
  var sampleWhole = false;
  _search(numbers, (last, steps, fraction) {
    final (_, text, division) = _canonical(last);
    found[text] = (whole: !fraction || (found[text]?.whole ?? false), division: division);
    if (sample == null || (!fraction && !sampleWhole)) {
      sample = List.unmodifiable(steps);
      sampleWhole = !fraction;
    }
    return false;
  });
  final ways = found.values;
  return (
    solutions: found.length,
    needsDivision: ways.isNotEmpty && ways.every((way) => way.division),
    needsFraction: ways.isNotEmpty && ways.every((way) => !way.whole),
    sample: sample,
  );
}

// 难度分（1–10）口径：先看非用不可的算法，再看解法多少（去掉交换律、结合律等价写法后的解法数，口径见 _canonical）：
// - 每种解法都要经过分数（如 3 3 8 8 只有 8 ÷ (3 − 8 ÷ 3)）：9，只有一种解法 10；
// - 每种解法都要用除法、但有不经过分数的：7，只有一种解法 8；
// - 只用加减乘就能解的，按解法数：8 种以上 1、5–7 种 2、4 种 3、3 种 4、2 种 5、只有 1 种 6。
// 各档按分数段出题（_scores），所以同档最多差 1 分、档与档之间不重叠地往上走。
// 1–13 的 1820 组数（不计顺序）里有解的 1362 组，按这把尺子：1–2 分 192 组（1–9 里 63 组）、3–4 分 357 组（1–10 里 170 组）、
// 5–6 分 614 组、7–8 分 183 组、9–10 分 16 组（3 3 8 8、1 5 5 5、3 3 7 7、1 3 4 6 这类）。没有解的题面不会出、也解码不进来，按 10 分算。
int twentyFourScore(TwentyFourAnalysis analysis) {
  final solutions = analysis.solutions;
  if (solutions == 0) return 10;
  if (analysis.needsFraction) return solutions == 1 ? 10 : 9;
  if (analysis.needsDivision) return solutions == 1 ? 8 : 7;
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

  // 每档的数从哪个区间里抽、难度分落在哪一段。入门、简单的数小，心算轻松；普通起用到 13。
  static const _ranges = {PuzzleTier.entry: (1, 9), PuzzleTier.easy: (1, 10), PuzzleTier.normal: (1, 13), PuzzleTier.hard: (1, 13), PuzzleTier.expert: (1, 13)};
  static const _scores = {PuzzleTier.entry: (1, 2), PuzzleTier.easy: (3, 4), PuzzleTier.normal: (5, 6), PuzzleTier.hard: (7, 8), PuzzleTier.expert: (9, 10)};

  // 出题：在这一档的区间里随机抽四个数，求解器确认有解、难度分落在这一档的分数段才用，否则重抽。
  // 专家档（9 分起，每种解法都要经过分数）平均抽百来次才中：先用只走整数、找到就停的求解筛掉（大多数组合几步就找到），
  // 剩下的才把全部走法列一遍。
  @override
  PuzzleDraw<TwentyFourPuzzle, List<TwentyFourStep>> generate(int seed, PuzzleTier tier) {
    final (low, high) = _ranges[tier]!;
    final (lowest, highest) = _scores[tier]!;
    final random = PuzzleRandom(seed);
    while (true) {
      final numbers = [for (var card = 0; card < twentyFourCards; card++) low + random.nextInt(high - low + 1)];
      if (lowest >= 9 && _wholeReachable(numbers)) continue;
      final analysis = twentyFourAnalyze(numbers);
      final score = twentyFourScore(analysis);
      if (analysis.sample == null || score < lowest || score > highest) continue;
      return PuzzleDraw(TwentyFourPuzzle(List.unmodifiable(numbers)), analysis.sample!);
    }
  }

  // 按规则重放：正好三步、每步合规，最后剩下的那张是 24。不和参考解比。
  @override
  bool solved(TwentyFourPuzzle puzzle, List<TwentyFourStep> answer) {
    if (answer.length != twentyFourCards - 1) return false;
    final slots = twentyFourReplay(puzzle, answer);
    return slots != null && slots.nonNulls.single == twentyFourTarget;
  }

  @override
  int difficulty(TwentyFourPuzzle puzzle) => twentyFourScore(twentyFourAnalyze(puzzle.numbers));

  // 题面编成四个数的列表（按位置顺序）。
  @override
  Object encodePuzzle(TwentyFourPuzzle puzzle) => [...puzzle.numbers];

  @override
  TwentyFourPuzzle decodePuzzle(Object? json) {
    final numbers = puzzleInts(json, maxLength: twentyFourCards, min: twentyFourMin, max: twentyFourMax);
    if (numbers.length != twentyFourCards) throw const FormatException('题目要四个数');
    if (twentyFourAnalyze(numbers).sample == null) throw const FormatException('这四个数算不出 24');
    return TwentyFourPuzzle(List.unmodifiable(numbers));
  }

  // 答案每步编成 [第一张的位置, 运算 code, 第二张的位置]，最多三步。
  @override
  Object encodeAnswer(List<TwentyFourStep> answer) => [
    for (final step in answer) [step.first, step.op.code, step.second],
  ];

  @override
  List<TwentyFourStep> decodeAnswer(Object? json) {
    if (json is! List || json.length >= twentyFourCards) throw const FormatException('答案不合法');
    return List.unmodifiable([
      for (final raw in json)
        if (puzzleInts(raw, maxLength: 3, min: 0, max: twentyFourCards - 1) case [final first, final code, final second])
          TwentyFourStep(first, TwentyFourOp.coded(code)!, second)
        else
          throw const FormatException('答案的一步不合法'),
    ]);
  }
}
