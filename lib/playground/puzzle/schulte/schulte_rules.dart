import 'package:superxd/playground/puzzle_rules.dart';

// 舒尔特方格（Schulte table）：方格里打乱排着一组数，按规定的顺序尽快依次点完，练视觉搜索与注意力。
// 入门到困难是单色的 3×3 到 6×6，按 1 到 N² 从小到大点；专家是 5×5 的红黑表（戈尔博夫–舒尔特红黑表的常见规则）：
// 黑色 1 到 13、红色 1 到 12，黑色从小到大、红色从大到小，两色交替点，黑色先点：黑 1、红 12、黑 2、红 11……红 1、黑 13。
// 拼的是手速，服务器核不了用时，只进自由模式（challengeable 为假）；规则照样按种子出题、按规则判定，测试与以后的工具共用。

// 题型：单色按 1 到 N² 点；红黑两色交替点。code 发出后不改（题面编码按它存）。
enum SchulteVariant {
  single('single'),
  redBlack('redBlack');

  const SchulteVariant(this.code);
  final String code;
}

// 一格里写的数：red 区分红黑表的两色，单色题都是 false（单色题的数与红黑表的黑色同样画实心格）。
typedef SchulteMark = ({bool red, int number});

class SchultePuzzle {
  const SchultePuzzle({required this.side, required this.variant, required this.numbers, required this.red});
  final int side;
  final SchulteVariant variant;
  // 按行优先：每格写的数，与这一格是不是红色（单色题全是 false）。
  final List<int> numbers;
  final List<bool> red;

  int get count => side * side;
  SchulteMark mark(int cell) => (red: red[cell], number: numbers[cell]);
}

// 题面边长只收档位里有的 3 到 6（外部输入的边界）。
const schulteMinSide = 3;
const schulteMaxSide = 6;

// 红黑表里红色有几个：格数是奇数时黑色多一个（黑色先点，也最后点）。
int schulteRedCount(int count) => count ~/ 2;

// 第 step 下（从 0 起）该点哪个数。题面上的数也正是这一串，每个恰好一格。
SchulteMark schulteTarget(SchulteVariant variant, int count, int step) => switch (variant) {
  SchulteVariant.single => (red: false, number: step + 1),
  SchulteVariant.redBlack => step.isEven ? (red: false, number: step ~/ 2 + 1) : (red: true, number: schulteRedCount(count) - step ~/ 2),
};

// 依次该点的格（参考解）：每一下的数在哪一格。
List<int> schulteSolution(SchultePuzzle puzzle) {
  final cells = {for (var cell = 0; cell < puzzle.count; cell++) puzzle.mark(cell): cell};
  return [for (var step = 0; step < puzzle.count; step++) cells[schulteTarget(puzzle.variant, puzzle.count, step)]!];
}

class SchulteRules extends PuzzleRules<SchultePuzzle, List<int>> {
  const SchulteRules();

  // 每档的边长与题型：专家不选 7×7，选 5×5 红黑表：6×6 到 7×7 只是多找几格，红黑表要同时记两色各点到哪、在同一个数的两种颜色里认对，
  // 是另一种注意力；7×7 在 360dp 宽上一格只剩 44dp 左右，拼手速时点偏的多是手指的问题而不是眼力。
  static const _tiers = {
    PuzzleTier.entry: (3, SchulteVariant.single),
    PuzzleTier.easy: (4, SchulteVariant.single),
    PuzzleTier.normal: (5, SchulteVariant.single),
    PuzzleTier.hard: (6, SchulteVariant.single),
    PuzzleTier.expert: (5, SchulteVariant.redBlack),
  };

  // 出题：把这一档要点的一串数按种子洗牌铺进格子，一定解得开，参考解就是每个数所在的格。
  @override
  PuzzleDraw<SchultePuzzle, List<int>> generate(int seed, PuzzleTier tier) {
    final (side, variant) = _tiers[tier]!;
    final count = side * side;
    final marks = [for (var step = 0; step < count; step++) schulteTarget(variant, count, step)];
    PuzzleRandom(seed).shuffle(marks);
    final puzzle = SchultePuzzle(side: side, variant: variant, numbers: [for (final mark in marks) mark.number], red: [for (final mark in marks) mark.red]);
    return PuzzleDraw(puzzle, schulteSolution(puzzle));
  }

  // 答案只记点对的那几下（点错不前进，次数由对局页另记）：要正好 N² 下，第几下就点第几个该点的数，顺序错、漏点、多点都不算。
  @override
  bool solved(SchultePuzzle puzzle, List<int> answer) {
    if (answer.length != puzzle.count) return false;
    for (final (step, cell) in answer.indexed) {
      if (cell < 0 || cell >= puzzle.count || puzzle.mark(cell) != schulteTarget(puzzle.variant, puzzle.count, step)) return false;
    }
    return true;
  }

  // 难度分：要找的格数，红黑表乘 2（按常见常模，红黑表每格用时是单色的两到三倍，取保守的 2），除以 7 加 1 再取整：
  // 入门 2、简单 3、普通 5、困难 6、专家 8。只看格数与题型，同档相同、逐档上升（与其他游戏入门约 2、专家七八分同一把尺子）。
  @override
  int difficulty(SchultePuzzle puzzle) => (puzzle.count * (puzzle.variant == SchulteVariant.redBlack ? 2 : 1) / 7 + 1).round().clamp(1, 10);

  // 题面编成边长、题型与每格的数（按行优先）；红黑表另加一串 0、1，1 是红色。
  @override
  Object encodePuzzle(SchultePuzzle puzzle) => {
    'side': puzzle.side,
    'variant': puzzle.variant.code,
    'numbers': [...puzzle.numbers],
    if (puzzle.variant == SchulteVariant.redBlack) 'red': puzzle.red.map((red) => red ? '1' : '0').join(),
  };

  @override
  SchultePuzzle decodePuzzle(Object? json) {
    final side = puzzleInt(json, 'side', min: schulteMinSide, max: schulteMaxSide);
    final map = json as Map;
    final variant = SchulteVariant.values.where((variant) => variant.code == map['variant']).firstOrNull ?? (throw const FormatException('题型不合法'));
    final count = side * side;
    final numbers = puzzleInts(map['numbers'], maxLength: count, min: 1, max: count);
    if (numbers.length != count) throw const FormatException('格数不对');
    final colors = map['red'];
    final List<bool> red;
    if (variant == SchulteVariant.single) {
      red = List.filled(count, false);
    } else if (colors is String && colors.length == count && RegExp(r'^[01]+$').hasMatch(colors)) {
      red = [for (final char in colors.split('')) char == '1'];
    } else {
      throw const FormatException('颜色不合法');
    }
    final puzzle = SchultePuzzle(side: side, variant: variant, numbers: numbers, red: red);
    // 每个该点的数恰好占一格：单色是 1 到 N² 各一次，红黑表是黑 1 到 13、红 1 到 12 各一次（5×5 时）。
    final marks = {for (var cell = 0; cell < count; cell++) puzzle.mark(cell)};
    if (marks.length != count || !marks.containsAll([for (var step = 0; step < count; step++) schulteTarget(variant, count, step)])) {
      throw const FormatException('题面不是每个数各一次');
    }
    return puzzle;
  }

  // 答案是依次点对的格（行优先下标）。
  @override
  Object encodeAnswer(List<int> answer) => [...answer];

  @override
  List<int> decodeAnswer(Object? json) => puzzleInts(json, maxLength: schulteMaxSide * schulteMaxSide, min: 0, max: schulteMaxSide * schulteMaxSide - 1);
}
