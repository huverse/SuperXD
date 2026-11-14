import 'package:superxd/domain/challenge.dart';

// 挑战里的一关交给对局页的东西（人工决策见 challenge_rules.dart）：这一关（题面已由服务器给出）、给玩家看的关名、到点时刻（本机钟）、
// 钥匙给哪一关，以及交答案（交给服务器核对，号码与重发由挑战那一局的控制器管）。对局页拿到它就不出题、不换档、不记本机成绩。
class PlayChallenge {
  const PlayChallenge({required this.level, required this.name, required this.deadline, required this.submit, this.target});
  final ChallengeLevel level;
  // 如「第 3 关」。
  final String name;
  final DateTime deadline;
  // 钥匙给哪一关（如「第 5 关」），这一关不给钥匙为空。
  final String? target;
  // 交一份答案（按这个游戏的规则编码）；连不上服务器抛 ChallengeException，这一次不算数，可以原样重交。
  final Future<PlayVerdict> Function(Object? answer) submit;
}

// 服务器的判定：对不对、解开后给的钥匙；over 是这一局已经结束（到点了或已结算），这一关不能再交。
class PlayVerdict {
  const PlayVerdict({required this.correct, this.key, this.over = false});
  final bool correct;
  final int? key;
  final bool over;
}

// 收钥匙的那几处写给玩家看：「第 2 张牌」「第 3 行的锁定皇后」「第 2 行第 4 格」（位置的口径同服务端 challenge_plan.ts 的预告）。
String challengeSlotName(String game, int at, Object? puzzle) => switch (game) {
  'twentyfour' => '第 ${at + 1} 张牌',
  'queens' => '第 ${at + 1} 行的锁定皇后',
  'loop' when puzzle is Map && puzzle['width'] is int => '第 ${at ~/ (puzzle['width'] as int) + 1} 行第 ${at % (puzzle['width'] as int) + 1} 格',
  _ => '第 ${at + 1} 处',
};
