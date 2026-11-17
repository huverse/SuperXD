import 'package:superxd/domain/challenge.dart';
import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/puzzle/flash/flash_rules.dart';
import 'package:superxd/playground/puzzle/knights/knights_rules.dart';
import 'package:superxd/playground/puzzle/logicgrid/logicgrid_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';

// 挑战里的一关交给对局页的东西（人工决策见 challenge_rules.dart 的 11-14 23:11 那条）：这一关（题面已由服务器给出）、给玩家看的关名、
// 到点时刻（本机钟），以及交答案（交给服务器核对，号码与重发由挑战那一局的控制器管）。对局页拿到它就不出题、不换档、不记本机成绩。
// 建的时候就按这个游戏的规则把题面解一次（服务器给的，外部输入边界），对局页直接用；题面、档位或改写的那一处这个版本认不得时
// （服务器换了写法而应用没更新）抛 FormatException，挑战那一页提示更新应用、不进这一关。
class PlayChallenge {
  PlayChallenge({required this.level, required this.name, required this.deadline, required this.submit}) : puzzle = _decode(level);
  final ChallengeLevel level;
  // 如「C 关」。
  final String name;
  final DateTime deadline;
  // 交一份答案（按这个游戏的规则编码）；连不上服务器抛 ChallengeException，这一次不算数，可以原样重交。
  final Future<PlayVerdict> Function(Object? answer) submit;
  // 解好的题面（这个游戏的题面类型）。
  final Object? puzzle;

  static Object? _decode(ChallengeLevel level) {
    final rules = challengeRules[level.game];
    if (rules == null || PuzzleTier.named(level.tier) == null) throw FormatException('认不得的游戏或档位 ${level.game}.${level.tier}');
    final puzzle = rules.decodePuzzle(level.puzzle);
    if (level.consume case ChallengeConsume(slot: true, :final at) when at < 0 || at >= challengeSlotRange(level.game, puzzle)) throw const FormatException('改写的那一处不在题面上');
    return puzzle;
  }

  // 补条件：题面上写成 ? 的那一处（24 点第几张牌、八皇后第几行、数回第几格、密码破译第几行、骑士与无赖第几个人），玩家按门上的数自己算；没有为空。
  int? get slot => switch (level.consume) {
    ChallengeConsume(slot: true, :final at) => at,
    _ => null,
  };

  // 改目标：汉诺塔不标目标柱、冰面滑行只标几个出口、记忆闪光要不要镜像，都由玩家按门上的数自己算。
  bool get goal => level.consume?.slot == false;
}

// 服务器的判定：对不对、过关给的碎片（只这一次给）与追加的加试题；over 是这一局已经结束（到点了或已结算），这一关不能再交。
class PlayVerdict {
  const PlayVerdict({required this.correct, this.fragment, this.extra, this.over = false});
  final bool correct;
  final int? fragment;
  final String? extra;
  final bool over;
}

// 关名：模板里的关用碎片的字母（「C 关」），加试题写「加试」。
String challengeLevelName(ChallengeLevel level) => level.letter == null ? '加试' : '${level.letter} 关';

// 碎片是什么（结果弹层与总览里写给玩家看）：从这一关的解里读出的那个数，口径同 challenge_rules.dart 的 challengeFragment。puzzle 是解好的题面（PlayChallenge.puzzle）。
String challengeFragmentName(String game, Object? puzzle) => switch (game) {
  'hanoi' || 'ice' => '最少步数',
  'lights' => '最少点几下',
  'boxes' => '最少推几次',
  'queens' => '最后一行的皇后在第几列',
  'river' => '最少渡河几次',
  'nonogram' => '一共涂几格',
  'knights' => '有几个骑士',
  'logicgrid' => '「${(puzzle as LogicGridPuzzle).categories.first.label(0)}」是第几个人',
  'cipher' => '密码各位之和',
  'twentyfour' => '四个数之和',
  'mines' => '第一行有几颗雷',
  'flash' => puzzle is FlashPuzzle && puzzle.variant == FlashVariant.numbers ? '最后一轮有几个数' : '最后一轮亮几格',
  'loop' => '圈里围住几格',
  'balance' => '称几次',
  _ => '碎片',
};

// 门上的数改写的那一处怎么算，写给玩家看：「第 3 张牌 = 37 ÷ 9 的余数 + 1」；门还没开（不知道门上的数）或不收碎片为空。
String? challengeConsumeText(ChallengeLevel level) {
  final consume = level.consume, key = level.gate?.value;
  if (consume == null || key == null) return null;
  final formula = consume.offset == 0 ? '$key ÷ ${consume.modulus} 的余数' : '$key ÷ ${consume.modulus} 的余数 + ${consume.offset}';
  final width = level.puzzle is Map ? (level.puzzle as Map)['width'] : null;
  return switch (level.game) {
    'twentyfour' => '第 ${consume.at + 1} 张牌 = $formula',
    'queens' => '第 ${consume.at + 1} 行的皇后在第几列 = $formula',
    'loop' when width is int => '第 ${consume.at ~/ width + 1} 行第 ${consume.at % width + 1} 格 = $formula',
    'cipher' => '第 ${consume.at + 1} 行的 ? = $formula',
    'knights' => '${knightsNames[consume.at]}话里的 ? = $formula',
    'hanoi' => '目标柱 = $formula',
    'ice' => '终点出口 = $formula',
    'flash' => '$key ÷ 2 余 1 就按左右镜像点',
    _ => null,
  };
}
