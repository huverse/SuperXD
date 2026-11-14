import 'package:superxd/playground/puzzle/balance/balance_rules.dart';
import 'package:superxd/playground/puzzle/boxes/boxes_rules.dart';
import 'package:superxd/playground/puzzle/cipher/cipher_rules.dart';
import 'package:superxd/playground/puzzle/flash/flash_rules.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_rules.dart';
import 'package:superxd/playground/puzzle/ice/ice_rules.dart';
import 'package:superxd/playground/puzzle/knights/knights_rules.dart';
import 'package:superxd/playground/puzzle/lights/lights_rules.dart';
import 'package:superxd/playground/puzzle/logicgrid/logicgrid_rules.dart';
import 'package:superxd/playground/puzzle/loop/loop_rules.dart';
import 'package:superxd/playground/puzzle/mines/mines_rules.dart';
import 'package:superxd/playground/puzzle/nonogram/nonogram_rules.dart';
import 'package:superxd/playground/puzzle/queens/queens_rules.dart';
import 'package:superxd/playground/puzzle/river/river_rules.dart';
import 'package:superxd/playground/puzzle/twentyfour/twentyfour_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';

// 挑战模式用到的规则（纯 Dart，不引 Flutter：tool 下的题库与向量工具直接跑）。
// [人工决策-2026-11-14 13:10:28] 第 3 阶段用户三项选择：
// 1. 关卡之间「钥匙填空」：解开一关、服务器核对通过才给这一关的钥匙（一个数）；后面某一关的题面里挖掉一个必要条件，正好由钥匙补上
//    （24 点的一张牌、八皇后一个锁定皇后的列、数回一个数字格），没拿到钥匙那一关解不唯一、做不出来。并联是几关的钥匙汇进同一关，
//    串联是收钥匙的那一关解开后又给下一关钥匙。钥匙的值就是被挖掉的那个条件的真值，由服务器在开局时分配给给钥匙的那一关（与那一关的题无关）。
// 2. 挑战以每周轮换为基础、灵活可改：挑战内容（模板、轮换、计分参数、限时、题库）都是服务器的配置与数据，改了热加载，不用发版；
//    客户端只按服务器给的关卡图通用地画，新游戏才要发版。
// 3. 服务器计时、不暂停：从点开始起算，切后台、来电照走，到点按已过的关结算。
// 能进挑战的游戏：登记项 challengeable 为真的 15 个，id 同注册表，发出后不改；服务器的判定（server/src/modules/challenge/judges）从这些规则逐个移植，
// 与这里共用测试向量 server/test/vectors/challenge_judge_v1.json（tool/challenge_vectors.dart 生成）。
const Map<String, PuzzleRules<Object?, Object?>> challengeRules = {
  'hanoi': HanoiRules(),
  'ice': IceRules(),
  'lights': LightsRules(),
  'boxes': BoxesRules(),
  'queens': QueensRules(),
  'river': RiverRules(),
  'nonogram': NonogramRules(),
  'knights': KnightsRules(),
  'logicgrid': LogicGridRules(),
  'cipher': CipherRules(),
  'twentyfour': TwentyFourRules(),
  'mines': MinesRules(),
  'flash': FlashRules(),
  'loop': LoopRules(),
  'balance': BalanceRules(),
};

// 一处能挖掉、由钥匙补上的必要条件：at 是位置（24 点第几张牌、八皇后第几行、数回第几格），value 是题面里的真值，key 是给玩家看的钥匙数
// （八皇后的列从 1 数，其余同 value）。
class ChallengeSlot {
  const ChallengeSlot({required this.at, required this.value, required this.key});
  final int at, value, key;

  Map<String, int> toJson() => {'at': at, 'value': value, 'key': key};
}

// 能收钥匙的游戏。
const challengeConsumers = {'twentyfour', 'queens', 'loop'};

// 一道题里单独挖掉也会让题解不唯一（或算不出）的条件，出题库时算好存进题库；挖几处由服务器按这一关收几把钥匙挑。
// 24 点四张牌缺了哪张都算不出；八皇后出题时就把多余的锁定皇后拿掉了，挖哪个都不唯一，这里照样再核一遍；数回逐个试，挖掉后仍唯一的不算。
List<ChallengeSlot> challengeSlots(String game, Object? puzzle) {
  switch (game) {
    case 'twentyfour':
      final numbers = (puzzle as TwentyFourPuzzle).numbers;
      return [for (final (index, number) in numbers.indexed) ChallengeSlot(at: index, value: number, key: number)];
    case 'queens':
      final queens = puzzle as QueensPuzzle;
      return [
        for (var row = 0; row < queens.size; row++)
          if (queens.given[row] >= 0 && queensSolve(QueensPuzzle(size: queens.size, given: [...queens.given]..[row] = -1)).count > 1)
            ChallengeSlot(at: row, value: queens.given[row], key: queens.given[row] + 1),
      ];
    case 'loop':
      final loop = puzzle as LoopPuzzle;
      return [
        for (var cell = 0; cell < loop.clues.length; cell++)
          if (loop.clues[cell] >= 0 && loopSolve(LoopPuzzle(width: loop.width, height: loop.height, clues: [...loop.clues]..[cell] = -1)).count > 1)
            ChallengeSlot(at: cell, value: loop.clues[cell], key: loop.clues[cell]),
      ];
    default:
      return const [];
  }
}
