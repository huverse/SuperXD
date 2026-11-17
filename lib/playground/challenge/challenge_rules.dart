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
// [人工决策-2026-11-14 13:10:28] 第 3 阶段用户三项选择（第 2、3 条仍有效，第 1 条的钥匙填空由下面 11-14 23:11 那条取代）：
// 1. 关卡之间「钥匙填空」：解开一关给一个数，补上后面某一关题面里挖掉的必要条件。
// 2. 挑战以每周轮换为基础、灵活可改：挑战内容（模板、轮换、计分参数、限时、题库）都是服务器的配置与数据，改了热加载，不用发版；
//    客户端只按服务器给的关卡图通用地画，新游戏才要发版。
// 3. 服务器计时、不暂停：从点开始起算，切后台、来电照走，到点按已过的关结算。
// [人工决策-2026-11-14 23:11:48] 用户看了参考页「七关连环挑战」后选「碎片从解里来并改目标」，四条规则全借鉴：
// 1. 碎片：每关过关时服务器给一次这一关的碎片（challengeFragment：从这一关的解里读出、所有正确解都一样的一个数，如最少步数、圈里几格），
//    只显示一次、要自己记；忘了就重做那一关再看一次（照样计时，不改成绩）。
// 2. 门：收碎片的关前面有一道门，门上的数 = 给它碎片的几关的碎片相加或相乘（只有一关就是那个碎片），输错扣时间、不说哪个碎片错了。
//    门开了，这一关被改写的那一处 = 门上的数除以 m 的余数加 o（m、o 由服务器按游戏与档位定）：补条件的那一处在题面上写成 ?，
//    改目标的是目标柱、真正的出口、要不要镜像；页面写出算式，自己算。能收碎片的游戏见 challengeConsumers。
// 3. 终章：全部碎片相加是最终密码，输对才算全部过关；某一关过得快得不正常，追加一道同一游戏的加试题，做完才开终章。
// 4. 困难与专家档的汉诺塔、冰面滑行、推箱子、点灯要用最少步数（challengeMinimum），多一步都不算过。
// [人工决策-2026-11-17 14:17:05] 上一条第 4 点的例外：汉诺塔（第 2 版）在困难、专家档走到最少步数的 1.2 倍以内（含、向下取整）就算过，
// 其他游戏照旧要正好最少；上限由各游戏规则的 stepLimit 给（challengeStepLimit，见 hanoi_rules.dart 的 hanoiStepPercent），服务端同口径。
// [人工决策-2026-11-15 19:18:31] 用户选「题面带版本号」（推荐）：每个游戏的题面写法有版本号（PuzzleRules.puzzleVersion，从 1 起，改了写法加一），
// 客户端报「游戏@版本」（challengeGameTokens），服务器只排、只下发认得的版本，题库按版本分文件。原因：服务器那边换了某个游戏的题面写法时，
// 没更新的应用照样能玩它认得的版本，不会进了关才发现看不懂（以前只按游戏名判断能不能玩）。
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

// 报给服务器的「游戏@题面写法版本」（如 hanoi@1）：只报能进挑战的，不认识的游戏不报（人工决策见文件头 11-15 19:18 那条）。
Set<String> challengeGameTokens(Iterable<String> games) => {
  for (final game in games)
    if (challengeRules[game] case final rules?) '$game@${rules.puzzleVersion}',
};

// 下面的名单与查询都从各游戏规则里的挑战特性取（[人工决策-2026-11-16 17:26:21] 见 puzzle_rules.dart 的 PuzzleRules.fragment），这里不再按游戏写 switch。
// 这一关的碎片（solution 是题库的参考解），过关时服务器给一次。
int? challengeFragment(String game, Object? puzzle, Object? solution) => challengeRules[game]?.fragment(puzzle, solution);

// 能收碎片的游戏（同服务端 consumerGames）：补条件的在题面上把那一处写成 ?，改目标的由服务器改写题面。
final challengeSlotGames = {for (final MapEntry(:key, :value) in challengeRules.entries) if (value.intake == PuzzleIntake.condition) key};
final challengeGoalGames = {for (final MapEntry(:key, :value) in challengeRules.entries) if (value.intake == PuzzleIntake.goal) key};
final challengeConsumers = {...challengeSlotGames, ...challengeGoalGames};

// 一道题里写成 ? 也做不出来的那几处，出题库时算好存进题库。
List<ChallengeSlot> challengeSlots(String game, Object? puzzle) => challengeRules[game]?.slots(puzzle) ?? const [];

// 补条件的那一处能落在哪些位置（0 到它减 1）：服务器给的位置先按它核一遍，对局页才按位置取题面里的那一项；不收补条件的游戏是 0。
int challengeSlotRange(String game, Object? puzzle) => challengeRules[game]?.slotRange(puzzle) ?? 0;

// 要用最少步数的游戏在困难与专家档的最少步数：汉诺塔、冰面滑行、点灯按步数，推箱子按推的次数。
int? challengeMinimum(String game, Object? puzzle) => challengeRules[game]?.minimum(puzzle);

// 要最少步数的关答案最多能走几步：多数游戏正好最少，汉诺塔放宽到 1.2 倍（人工决策见文件头 11-17 14:17:05 那条）。
int challengeStepLimit(String game, int minimum) => challengeRules[game]?.stepLimit(minimum) ?? minimum;
