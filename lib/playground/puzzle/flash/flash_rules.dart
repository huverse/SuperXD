import 'package:superxd/playground/puzzle_rules.dart';

// 记忆闪光：五档各练一种记忆，难度逐档上升（参考 Lumosity 的 Memory Matrix、Corsi 方块测试与 Human Benchmark 的黑猩猩测试）：
// 入门、简单是位置记忆（同时亮起几格，熄灭后点齐，顺序不限）；普通是顺序记忆（格子一个接一个亮，按亮的先后点）；
// 困难是倒序记忆（同样一个接一个亮，倒着点，最后亮的先点）；专家是数字顺序（随机几格写着 1 到 N，到时间或点了第一下就藏成空白块，按从小到大点）。
// 一道题固定几轮，每轮全点对才进下一轮；点错一下这一次就作废，换这一轮的下一组重来。
// 题面直接列出每轮的全部组（这一轮的加备用），核对答案只要按规则重放，不用复现出题的随机过程。

// 题型：code 发出后不改（题面编码按它存）。
enum FlashVariant {
  spot('spot'),
  sequence('sequence'),
  reverse('reverse'),
  numbers('numbers');

  const FlashVariant(this.code);
  final String code;

  // 按先后点（顺序、倒序、数字顺序）；位置记忆顺序不限。
  bool get ordered => this != spot;
  // 一格接一格亮（顺序、倒序）：题面另带格与格之间暗多久。
  bool get stepwise => this == sequence || this == reverse;
}

class FlashPuzzle {
  const FlashPuzzle({required this.side, required this.variant, required this.showMillis, this.gapMillis = 0, required this.rounds, this.mirror = false});
  final int side;
  final FlashVariant variant;
  // 亮多久（毫秒）：位置记忆是整组亮多久，顺序与倒序是每格亮多久，数字顺序是每个数摊到的显示时长（N 个数一共显示 N 倍，见 flashExposure）。
  final int showMillis;
  // 顺序与倒序里一格熄灭到下一格亮起之间暗多久；其余题型为 0。
  final int gapMillis;
  // rounds[第几轮][第几组] 是这一组的格（行优先下标）：位置记忆是亮的格、升序；顺序与倒序按亮的先后排；数字顺序第 i 个是写着 i + 1 的格。
  // 第一组是这一轮的，后面是点错后依次换上的备用，备用用完从第一组接着轮换。同一轮的几组格数相同、互不相同，一组里没有重格。
  final List<List<List<int>>> rounds;
  // 挑战里收碎片的关：碎片算出来要镜像时，亮的照常亮，要点的是左右镜像的格（先后与数字不变，人工决策见 challenge_rules.dart）；平时为假。
  final bool mirror;

  // 同一道题要点镜像的那一版（挑战改目标时服务器把题面的 mirror 写成真；向量工具与测试用）。
  FlashPuzzle get mirrored => FlashPuzzle(side: side, variant: variant, showMillis: showMillis, gapMillis: gapMillis, rounds: rounds, mirror: true);
}

// 题面边长、每轮几组、亮与暗的时长与答案长度的上限（解码是外部输入的边界）。
const flashMinSide = 3;
const flashMaxSide = 6;
const flashMaxRounds = 10;
const flashMaxPatterns = 8;
const flashMinShowMillis = 200;
const flashMaxShowMillis = 3000;
const flashMaxGapMillis = 1000;
// 一局最多记这么多次尝试（每次点错算一次，留足自由模式里反复点错的余地）。
const flashMaxAttempts = 400;
// 出题：每道题 5 轮，每轮 1 组加 5 组备用。
const flashRounds = 5;
const flashPatternsPerRound = 6;

// 第 round 轮第 attempt 次尝试（从 0 数，点错一次加一）亮的那组：备用用完从头轮换。
List<int> flashShown(FlashPuzzle puzzle, int round, int attempt) => puzzle.rounds[round][attempt % puzzle.rounds[round].length];

// 左右镜像的那一格。
int flashMirror(int side, int cell) => cell ~/ side * side + side - 1 - cell % side;

// 这一次要点的格：位置记忆是亮的那组（升序，顺序不限）；顺序与数字顺序按亮的先后（数字从小到大），倒序反过来。
// 镜像时每格换成左右镜像的格，先后与数字不变（位置记忆重新排成升序）。
List<int> flashPattern(FlashPuzzle puzzle, int round, int attempt) {
  final shown = flashShown(puzzle, round, attempt);
  final cells = puzzle.mirror ? [for (final cell in shown) flashMirror(puzzle.side, cell)] : shown;
  return switch (puzzle.variant) {
    FlashVariant.spot when puzzle.mirror => cells..sort(),
    FlashVariant.reverse => cells.reversed.toList(),
    _ => cells,
  };
}

// 一组 count 格从亮起到熄灭（数字顺序是到藏起）的毫秒数：位置记忆整组亮 show；顺序与倒序每格亮 show、格与格之间暗 gap；
// 数字顺序每个数 show（没到时间点了第一下也藏起）。
int flashExposure(FlashPuzzle puzzle, int count) => switch (puzzle.variant) {
  FlashVariant.spot => puzzle.showMillis,
  FlashVariant.sequence || FlashVariant.reverse => count * puzzle.showMillis + (count - 1) * puzzle.gapMillis,
  FlashVariant.numbers => count * puzzle.showMillis,
};

// 一次尝试里点一格的结果：不响应的（已点亮的格；数字顺序里不是数字块的格，同黑猩猩测试只有块能点）不算一下；
// 该点的算点对（位置记忆是这组里没点过的哪一格都行，按先后点的要正好是下一格），点齐这一组就过了这一轮；其余算点错，这一次就此作废。
enum FlashTap { ignored, hit, cleared, missed }

// hits 是这一次已点对的格（按点的先后），一定比 pattern 短（点齐就不再点）。
FlashTap flashTap(FlashVariant variant, List<int> pattern, List<int> hits, int cell) {
  if (hits.contains(cell) || (variant == FlashVariant.numbers && !pattern.contains(cell))) return FlashTap.ignored;
  final right = variant.ordered ? pattern[hits.length] == cell : pattern.contains(cell);
  return !right
      ? FlashTap.missed
      : hits.length + 1 == pattern.length
      ? FlashTap.cleared
      : FlashTap.hit;
}

// 按规则重放答案（每次尝试点的格依次排开），返回点错的次数；答案不合规或没走完全部轮次返回 null。
// 合规：每次尝试按这一轮第几次取要点的格（flashPattern），之前的尝试都正好结束在第一个点错的格上，每轮最后一次正好点齐、没有多点；
// 点棋盘外的格、不响应的格（页面里不会记下）、空的一次都不合规。
int? flashMistakes(FlashPuzzle puzzle, List<List<int>> attempts) {
  if (attempts.length > flashMaxAttempts) return null;
  final count = puzzle.side * puzzle.side;
  var round = 0, tries = 0, mistakes = 0;
  for (final taps in attempts) {
    if (round == puzzle.rounds.length) return null;
    final pattern = flashPattern(puzzle, round, tries);
    final hits = <int>[];
    FlashTap? last;
    for (final cell in taps) {
      // 这一次已经点齐或点错还有点按（多点、点错后接着点），或点了棋盘外的格。
      if (last == FlashTap.cleared || last == FlashTap.missed || cell < 0 || cell >= count) return null;
      last = flashTap(puzzle.variant, pattern, hits, cell);
      if (last == FlashTap.ignored) return null;
      hits.add(cell);
    }
    switch (last) {
      case FlashTap.cleared:
        round++;
        tries = 0;
      case FlashTap.missed:
        mistakes++;
        tries++;
      // 没点齐也没点错就结束了（少点），或空的一次。
      case FlashTap.hit || FlashTap.ignored || null:
        return null;
    }
  }
  return round == puzzle.rounds.length ? mistakes : null;
}

// 整行、整列或一整条对角线全占：一眼就是一条线，不用记，出题时不要。
bool flashHasLine(int side, Set<int> lit) {
  bool full(Iterable<int> cells) => cells.every(lit.contains);
  for (var index = 0; index < side; index++) {
    if (full([for (var column = 0; column < side; column++) index * side + column])) return true;
    if (full([for (var row = 0; row < side; row++) row * side + index])) return true;
  }
  return full([for (var index = 0; index < side; index++) index * side + index]) || full([for (var index = 0; index < side; index++) index * side + side - 1 - index]);
}

class FlashRules extends PuzzleRules<FlashPuzzle, List<List<int>>> {
  const FlashRules();

  // 第 2 版（11-16 五档改成五种记忆）：加了题型与顺序、倒序的格间暗多久，按先后点的组按先后排（不再都是升序）。
  @override
  int get puzzleVersion => 2;

  // 挑战里的特性（[人工决策-2026-11-16 17:26:21] 见 puzzle_rules.dart 的 PuzzleRules.fragment）。
  // 碎片是最后一轮的格数（位置记忆亮几格、顺序与倒序多长、数字顺序到几）；改目标是要不要点镜像。
  @override
  int? fragment(FlashPuzzle puzzle, List<List<int>> solution) => puzzle.rounds.last.first.length;
  @override
  PuzzleIntake? get intake => PuzzleIntake.goal;
  @override
  int penalties(FlashPuzzle puzzle, List<List<int>> answer) => flashMistakes(puzzle, answer)!;

  // 每档的题型、边长、每轮格数的区间与时长：格数在 5 轮里从 low 递增到 high（第 round 轮 low + (high - low + 1) × round ÷ 5 格：
  // 入门 3、3、4、4、5，简单 5、5、6、7、8，普通与困难 4、4、5、6、7，专家 6 到 10）；show 与 gap 的意思见 FlashPuzzle。
  static const _tiers = {
    PuzzleTier.entry: (variant: FlashVariant.spot, side: 4, low: 3, high: 5, show: 1500, gap: 0),
    PuzzleTier.easy: (variant: FlashVariant.spot, side: 5, low: 5, high: 8, show: 1600, gap: 0),
    PuzzleTier.normal: (variant: FlashVariant.sequence, side: 5, low: 4, high: 7, show: 700, gap: 250),
    PuzzleTier.hard: (variant: FlashVariant.reverse, side: 6, low: 4, high: 7, show: 700, gap: 250),
    PuzzleTier.expert: (variant: FlashVariant.numbers, side: 6, low: 6, high: 10, show: 300, gap: 0),
  };

  // 出题：每组把全部格洗一遍取前几格（位置记忆升序存，按先后点的就按洗出来的先后），整行、整列、整条对角线全占的不要（flashHasLine），
  // 格和这道题里已有的任何一组一样的也不要（只换了先后也算一样；同一轮换上的备用一定是新的格，各轮也不重样）；参考解是每轮照第一组点。
  @override
  PuzzleDraw<FlashPuzzle, List<List<int>>> generate(int seed, PuzzleTier tier) {
    final (:variant, :side, :low, :high, :show, :gap) = _tiers[tier]!;
    final random = PuzzleRandom(seed);
    final cells = [for (var cell = 0; cell < side * side; cell++) cell];
    final seen = <String>{};
    List<int> pattern(int count) {
      while (true) {
        random.shuffle(cells);
        final picked = cells.take(count).toList();
        final sorted = [...picked]..sort();
        if (!flashHasLine(side, sorted.toSet()) && seen.add(sorted.join(','))) return variant.ordered ? picked : sorted;
      }
    }

    final rounds = [
      for (var round = 0; round < flashRounds; round++)
        [for (var spare = 0; spare < flashPatternsPerRound; spare++) pattern(low + (high - low + 1) * round ~/ flashRounds)],
    ];
    final puzzle = FlashPuzzle(side: side, variant: variant, showMillis: show, gapMillis: gap, rounds: rounds);
    return PuzzleDraw(puzzle, [for (var round = 0; round < flashRounds; round++) [...flashPattern(puzzle, round, 0)]]);
  }

  @override
  bool solved(FlashPuzzle puzzle, List<List<int>> answer) => flashMistakes(puzzle, answer) != null;

  // 一组的记忆负荷（约等于要记几件事）：位置记忆的格能连成形状一起记，一格算 0.55 件；顺序一格一件；倒序还要在脑子里倒一遍，一格 1.4 件；
  // 数字顺序一个数 1.2 件（块的位置看得见、记的是先后，但每个数只给 0.3 秒左右）。
  static double _load(FlashVariant variant, int count) =>
      count *
      switch (variant) {
        FlashVariant.spot => .55,
        FlashVariant.sequence => 1.0,
        FlashVariant.reverse => 1.4,
        FlashVariant.numbers => 1.2,
      };

  // 预计用时：按轮累加。一次尝试 = 亮的时长（flashExposure）+ 每格作答（位置记忆要在棋盘上找，一格 1 秒；按先后点一格 0.9 秒）
  // + 暗一下与点错后看答案约 1.7 秒；一轮要试的次数估成 1 + 0.03 × 负荷²（入门第一轮约 1.1 次，专家最后一轮约 5 次），每轮另有约 1 秒的停顿。
  // 按各档参数算：入门约 45 秒、简单 70、普通 110、困难 160、专家 230（同一档参数相同所以用时相同）。
  @override
  int expectedSeconds(FlashPuzzle puzzle) {
    final tap = puzzle.variant.ordered ? .9 : 1.0;
    return puzzle.rounds.fold(0.0, (sum, patterns) {
      final count = patterns.first.length, load = _load(puzzle.variant, count);
      return sum + (1 + .03 * load * load) * (flashExposure(puzzle, count) / 1000 + count * tap + 1.7) + 1;
    }).round();
  }

  // 难易分：每轮平均的记忆负荷 × 0.85 + 0.5，再取整（只看每轮的第一组：备用只在点错后才用到；各档都是 5 轮，轮数不进分数）。
  // 按各档参数算：入门 2、简单 3、普通 5、困难 7、专家 9；同一档的参数相同所以分数相同，档与档之间往上走。
  @override
  int complexity(FlashPuzzle puzzle) {
    final load = puzzle.rounds.fold(0.0, (sum, patterns) => sum + _load(puzzle.variant, patterns.first.length)) / puzzle.rounds.length;
    return (load * .85 + .5).round().clamp(1, 10);
  }

  // 题面编成边长、题型、亮的毫秒数（顺序与倒序另有格间暗的毫秒数）与每轮的几组（位置记忆每组升序，按先后点的按先后排）。
  @override
  Object encodePuzzle(FlashPuzzle puzzle) => {
    'side': puzzle.side,
    'variant': puzzle.variant.code,
    'show': puzzle.showMillis,
    if (puzzle.variant.stepwise) 'gap': puzzle.gapMillis,
    'rounds': [for (final patterns in puzzle.rounds) [for (final pattern in patterns) [...pattern]]],
    if (puzzle.mirror) 'mirror': true,
  };

  // 解码校验：题型认得；顺序与倒序要有格间暗的毫秒数、其余题型不许有；轮数与每轮组数在上限内；每组的格在棋盘内、至少 1 格且不超过棋盘的一半、
  // 没有重格（位置记忆还要严格升序）；同一轮几组的格数相同、互不相同。
  @override
  FlashPuzzle decodePuzzle(Object? json) {
    final side = puzzleInt(json, 'side', min: flashMinSide, max: flashMaxSide);
    final map = json! as Map;
    final variant = FlashVariant.values.where((variant) => variant.code == map['variant']).firstOrNull ?? (throw const FormatException('题型不合法'));
    final show = puzzleInt(map, 'show', min: flashMinShowMillis, max: flashMaxShowMillis);
    final gap = variant.stepwise ? puzzleInt(map, 'gap', min: 0, max: flashMaxGapMillis) : (map.containsKey('gap') ? throw const FormatException('格间不合法') : 0);
    final rounds = map['rounds'];
    if (rounds is! List || rounds.isEmpty || rounds.length > flashMaxRounds) throw const FormatException('轮数不合法');
    final mirror = map['mirror'] ?? false;
    if (mirror is! bool) throw const FormatException('镜像不合法');
    return FlashPuzzle(side: side, variant: variant, showMillis: show, gapMillis: gap, rounds: [for (final patterns in rounds) _decodeRound(patterns, side, variant)], mirror: mirror);
  }

  static List<List<int>> _decodeRound(Object? json, int side, FlashVariant variant) {
    if (json is! List || json.isEmpty || json.length > flashMaxPatterns) throw const FormatException('一轮的图案不合法');
    final patterns = [for (final pattern in json) puzzleInts(pattern, maxLength: side * side ~/ 2, min: 0, max: side * side - 1)];
    final seen = <String>{};
    for (final pattern in patterns) {
      if (pattern.isEmpty || pattern.length != patterns.first.length || !seen.add(pattern.join(','))) throw const FormatException('一轮的图案不合法');
      if (pattern.toSet().length != pattern.length) throw const FormatException('图案的格不合法');
      for (var index = 1; index < pattern.length && !variant.ordered; index++) {
        if (pattern[index] <= pattern[index - 1]) throw const FormatException('图案的格不合法');
      }
    }
    return patterns;
  }

  // 答案是每次尝试依次点的格（含点错的那次），最多 flashMaxAttempts 次。
  @override
  Object encodeAnswer(List<List<int>> answer) => [for (final taps in answer) [...taps]];

  @override
  List<List<int>> decodeAnswer(Object? json) {
    if (json is! List || json.length > flashMaxAttempts) throw const FormatException('答案不合法');
    return [for (final taps in json) puzzleInts(taps, maxLength: flashMaxSide * flashMaxSide, min: 0, max: flashMaxSide * flashMaxSide - 1)];
  }
}
