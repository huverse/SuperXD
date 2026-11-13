import 'package:superxd/playground/puzzle_rules.dart';

// 记忆闪光（记忆矩阵）：棋盘上同时亮起几格，停一会儿熄灭，把刚才亮过的格子全部点出来（顺序不限）。
// 一道题固定几轮，每轮全点对才进下一轮；点错一格这一次就作废，换这一轮的下一组图案重来。
// 题面直接列出每轮的全部图案（主图案加备用），核对答案只要按规则重放，不用复现出题的随机过程。
class FlashPuzzle {
  const FlashPuzzle({required this.side, required this.showMillis, required this.rounds});
  final int side;
  // 每组图案亮多久（毫秒）。
  final int showMillis;
  // rounds[第几轮][第几组] 是这一组亮的格（行优先下标、升序）：第一组是这一轮的图案，后面是点错后依次换上的备用，
  // 备用用完从第一组接着轮换。同一轮的几组亮的格数相同、互不相同。
  final List<List<List<int>>> rounds;
}

// 题面边长、每轮几组、亮的时长与答案长度的上限（解码是外部输入的边界）。
const flashMinSide = 3;
const flashMaxSide = 6;
const flashMaxRounds = 10;
const flashMaxPatterns = 8;
const flashMinShowMillis = 500;
const flashMaxShowMillis = 3000;
// 一局最多记这么多次尝试（每次点错算一次，留足自由模式里反复点错的余地）。
const flashMaxAttempts = 400;
// 出题：每道题 5 轮，每轮 1 组图案加 5 组备用。
const flashRounds = 5;
const flashPatternsPerRound = 6;

// 第 round 轮第 attempt 次尝试（从 0 数，点错一次加一）要点的图案：备用用完从头轮换。
List<int> flashPattern(FlashPuzzle puzzle, int round, int attempt) => puzzle.rounds[round][attempt % puzzle.rounds[round].length];

// 一次尝试里点一格的结果：已点亮的格不响应（不算一下）；在图案里算点对，点齐这一组就过了这一轮；不在图案里算点错，这一次就此作废。
enum FlashTap { repeated, hit, cleared, missed }

FlashTap flashTap(List<int> pattern, Set<int> hits, int cell) => hits.contains(cell)
    ? FlashTap.repeated
    : !pattern.contains(cell)
    ? FlashTap.missed
    : hits.length + 1 == pattern.length
    ? FlashTap.cleared
    : FlashTap.hit;

// 按规则重放答案（每次尝试点的格依次排开），返回点错的次数；答案不合规或没走完全部轮次返回 null。
// 合规：每次尝试按这一轮第几次取图案（flashPattern），之前的尝试都正好结束在第一个点错的格上，每轮最后一次正好点齐、没有多点；
// 点棋盘外的格、点已点亮的格（页面里不响应，不会记下）、空的一次都不合规。
int? flashMistakes(FlashPuzzle puzzle, List<List<int>> attempts) {
  if (attempts.length > flashMaxAttempts) return null;
  final count = puzzle.side * puzzle.side;
  var round = 0, tries = 0, mistakes = 0;
  for (final taps in attempts) {
    if (round == puzzle.rounds.length) return null;
    final pattern = flashPattern(puzzle, round, tries);
    final hits = <int>{};
    FlashTap? last;
    for (final cell in taps) {
      // 这一次已经点齐或点错还有点按（多点、点错后接着点），或点了棋盘外的格。
      if (last == FlashTap.cleared || last == FlashTap.missed || cell < 0 || cell >= count) return null;
      last = flashTap(pattern, hits, cell);
      if (last == FlashTap.repeated) return null;
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
      case FlashTap.hit || FlashTap.repeated || null:
        return null;
    }
  }
  return round == puzzle.rounds.length ? mistakes : null;
}

// 整行、整列或一整条对角线全亮：一眼就是一条线，不用记，出题时不要。
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

  // 每档的边长、每轮亮的格数区间与亮的时长：格数在 5 轮里从 low 递增到 high（第 round 轮亮 low + (high - low + 1) × round ÷ 5 格，
  // 入门 3、3、3、4、4，专家 10、10、11、11、12）；档越高格子越多、亮的格越多、亮的时间越短。
  static const _tiers = {
    PuzzleTier.entry: (side: 3, low: 3, high: 4, show: 1500),
    PuzzleTier.easy: (side: 4, low: 4, high: 5, show: 1400),
    PuzzleTier.normal: (side: 5, low: 6, high: 7, show: 1300),
    PuzzleTier.hard: (side: 6, low: 8, high: 9, show: 1200),
    PuzzleTier.expert: (side: 6, low: 10, high: 12, show: 1000),
  };

  // 出题：每组图案把全部格洗一遍取前几格（升序存），整行、整列、整条对角线全亮的不要（flashHasLine），
  // 和这道题里已有的任何一组相同的也不要（同一轮换上的备用一定是新图案，各轮也不重样）；参考解是每轮按升序点第一组。
  @override
  PuzzleDraw<FlashPuzzle, List<List<int>>> generate(int seed, PuzzleTier tier) {
    final (:side, :low, :high, :show) = _tiers[tier]!;
    final random = PuzzleRandom(seed);
    final cells = [for (var cell = 0; cell < side * side; cell++) cell];
    final seen = <String>{};
    List<int> pattern(int count) {
      while (true) {
        random.shuffle(cells);
        final picked = cells.take(count).toList()..sort();
        if (!flashHasLine(side, picked.toSet()) && seen.add(picked.join(','))) return picked;
      }
    }

    final rounds = [
      for (var round = 0; round < flashRounds; round++)
        [for (var spare = 0; spare < flashPatternsPerRound; spare++) pattern(low + (high - low + 1) * round ~/ flashRounds)],
    ];
    return PuzzleDraw(FlashPuzzle(side: side, showMillis: show, rounds: rounds), [for (final patterns in rounds) [...patterns.first]]);
  }

  @override
  bool solved(FlashPuzzle puzzle, List<List<int>> answer) => flashMistakes(puzzle, answer) != null;

  // 难度分：格数 ÷ 12（要扫的棋盘多大）加「每轮平均亮几格 × 1500 ÷ 亮的毫秒数」÷ 2.6（要记的格多少，亮得越短越难记），再取整。
  // 按各档参数算：入门 2、简单 3、普通 5、困难 7、专家 9；同一档的参数相同所以分数相同，档与档之间往上走
  // （与点灯、汉诺塔入门约 2 分、专家七八分同一把尺子）。只看每轮的第一组：备用只在点错后才用到；各档都是 5 轮，轮数不进分数。
  @override
  int difficulty(FlashPuzzle puzzle) {
    final lit = puzzle.rounds.fold(0, (sum, patterns) => sum + patterns.first.length) / puzzle.rounds.length;
    return (puzzle.side * puzzle.side / 12 + lit * 1500 / puzzle.showMillis / 2.6).round().clamp(1, 10);
  }

  // 题面编成边长、亮的毫秒数与每轮的几组图案（每组是升序的格下标）。
  @override
  Object encodePuzzle(FlashPuzzle puzzle) => {
    'side': puzzle.side,
    'show': puzzle.showMillis,
    'rounds': [for (final patterns in puzzle.rounds) [for (final pattern in patterns) [...pattern]]],
  };

  // 解码校验：轮数与每轮组数在上限内；每组的格在棋盘内、严格升序（没有重格）、至少 1 格且不超过棋盘的一半；同一轮几组的格数相同、互不相同。
  @override
  FlashPuzzle decodePuzzle(Object? json) {
    final side = puzzleInt(json, 'side', min: flashMinSide, max: flashMaxSide);
    final show = puzzleInt(json, 'show', min: flashMinShowMillis, max: flashMaxShowMillis);
    final rounds = (json as Map)['rounds'];
    if (rounds is! List || rounds.isEmpty || rounds.length > flashMaxRounds) throw const FormatException('轮数不合法');
    return FlashPuzzle(side: side, showMillis: show, rounds: [for (final patterns in rounds) _decodeRound(patterns, side)]);
  }

  static List<List<int>> _decodeRound(Object? json, int side) {
    if (json is! List || json.isEmpty || json.length > flashMaxPatterns) throw const FormatException('一轮的图案不合法');
    final patterns = [for (final pattern in json) puzzleInts(pattern, maxLength: side * side ~/ 2, min: 0, max: side * side - 1)];
    final seen = <String>{};
    for (final pattern in patterns) {
      if (pattern.isEmpty || pattern.length != patterns.first.length || !seen.add(pattern.join(','))) throw const FormatException('一轮的图案不合法');
      for (var index = 1; index < pattern.length; index++) {
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
