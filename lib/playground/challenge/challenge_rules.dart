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

// 这一关的碎片（solution 是题库的参考解）：从解里读出、所有正确解都一样，题库里存好，过关时服务器给一次。
// 天平称球的球是玩家称出来的（秤不预定假球），没有固定的「不同的那个球」，碎片用题面定的称几次（每档都正好够用，也就是最少要称几次）。
int? challengeFragment(String game, Object? puzzle, Object? solution) => switch (game) {
  'hanoi' => hanoiMinMoves((puzzle as HanoiPuzzle).start, puzzle.target),
  'ice' => iceMinMoves(puzzle as IcePuzzle),
  'lights' => lightsSolve(puzzle as LightsPuzzle)!.length,
  'boxes' => boxesSolve(puzzle as BoxesPuzzle)!.pushes,
  'queens' => (solution as List<int>).last + 1,
  'river' => riverSolve(puzzle as RiverPuzzle)!.length,
  'nonogram' => (solution as List<bool>).where((cell) => cell).length,
  'knights' => (solution as List<bool>).where((knight) => knight).length,
  'logicgrid' => (solution as List<List<int>>).first.indexOf(0) + 1,
  'cipher' => (solution as List<int>).fold<int>(0, (sum, digit) => sum + digit),
  'twentyfour' => (puzzle as TwentyFourPuzzle).numbers.fold<int>(0, (sum, number) => sum + number),
  'mines' => (puzzle as MinesPuzzle).mines.take(puzzle.width).where((mine) => mine).length,
  'flash' => (puzzle as FlashPuzzle).rounds.last.first.length,
  'loop' => loopInside(puzzle as LoopPuzzle, solution as List<bool>),
  'balance' => (puzzle as BalancePuzzle).weighings,
  _ => null,
};

// 圈里围住几格：每一格往左数，这一行左边在圈上的竖边是奇数条就在圈里。
int loopInside(LoopPuzzle puzzle, List<bool> edges) {
  final grid = LoopGrid.of(puzzle.width, puzzle.height);
  var inside = 0;
  for (var row = 0; row < puzzle.height; row++) {
    var crossings = 0;
    for (var column = 0; column < puzzle.width; column++) {
      if (edges[grid.vertical(row, column)]) crossings++;
      if (crossings.isOdd) inside++;
    }
  }
  return inside;
}

// 能收碎片的游戏（同服务端 consumerGames）：补条件的在题面上把那一处写成 ?（challengeSlots 给能挖的位置与真值），
// 改目标的由服务器改写题面（汉诺塔的目标柱、冰面滑行的真出口 iceExits、记忆闪光要不要镜像）。
const challengeSlotGames = {'twentyfour', 'queens', 'loop', 'cipher', 'knights'};
const challengeGoalGames = {'hanoi', 'ice', 'flash'};
const challengeConsumers = {...challengeSlotGames, ...challengeGoalGames};

// 能由碎片补上的一处：at 是位置（24 点第几张牌、八皇后第几行、数回第几格、密码破译第几行的「位置也对」、骑士与无赖第几个人那句话的人数），
// value 是题面里的真值（八皇后是从 0 数的列）。
class ChallengeSlot {
  const ChallengeSlot({required this.at, required this.value});
  final int at, value;

  Map<String, int> toJson() => {'at': at, 'value': value};
}

// 一道题里写成 ? 也做不出来（不知道它就解不唯一或推不下去）的那几处，出题库时算好存进题库；服务器按门上的数挑真值对得上的一处。
// 24 点四张牌缺了哪张都算不出；八皇后出题时就把多余的锁定皇后拿掉了，这里照样再核一遍；数回、密码破译、骑士与无赖换个值仍有解才算。
// 数织试过只有一段的行：不看那一行的提示逐行推不下去的，40 道里只有一两道，不收碎片。
List<ChallengeSlot> challengeSlots(String game, Object? puzzle) {
  switch (game) {
    case 'twentyfour':
      return [for (final (index, number) in (puzzle as TwentyFourPuzzle).numbers.indexed) ChallengeSlot(at: index, value: number)];
    case 'queens':
      final queens = puzzle as QueensPuzzle;
      return [
        for (var row = 0; row < queens.size; row++)
          if (queens.given[row] >= 0 && queensSolve(QueensPuzzle(size: queens.size, given: [...queens.given]..[row] = -1)).count > 1)
            ChallengeSlot(at: row, value: queens.given[row]),
      ];
    case 'loop':
      final loop = puzzle as LoopPuzzle;
      return [
        for (var cell = 0; cell < loop.clues.length; cell++)
          if (loop.clues[cell] >= 0 && loopSolve(LoopPuzzle(width: loop.width, height: loop.height, clues: [...loop.clues]..[cell] = -1)).count > 1)
            ChallengeSlot(at: cell, value: loop.clues[cell]),
      ];
    case 'cipher':
      final cipher = puzzle as CipherPuzzle;
      return [
        for (final (index, row) in cipher.rows.indexed)
          if ([
            for (var exact = 0; exact <= cipher.length - row.misplaced; exact++)
              if (exact != row.exact) CipherPuzzle(length: cipher.length, digits: cipher.digits, rows: [...cipher.rows]..[index] = CipherRow(row.guess, exact, row.misplaced)),
          ].any((other) => cipherSolve(other, limit: 1).count > 0))
            ChallengeSlot(at: index, value: row.exact),
      ];
    case 'knights':
      final knights = puzzle as KnightsPuzzle;
      const counted = {KnightsClaimKind.exactly, KnightsClaimKind.atLeast, KnightsClaimKind.atMost};
      return [
        for (final (speaker, claim) in knights.claims.indexed)
          if (counted.contains(claim.kind) &&
              [
                for (var count = 0; count <= knights.people; count++)
                  if (count != claim.first) KnightsPuzzle([...knights.claims]..[speaker] = KnightsClaim(claim.kind, count)),
              ].any((other) => knightsSolutions(other).isNotEmpty))
            ChallengeSlot(at: speaker, value: claim.first),
      ];
    default:
      return const [];
  }
}

// 补条件的那一处能落在哪些位置（0 到它减 1）：服务器给的位置先按它核一遍，对局页才按位置取题面里的那一项；不收补条件的游戏是 0。
int challengeSlotRange(String game, Object? puzzle) => switch (game) {
  'twentyfour' => (puzzle as TwentyFourPuzzle).numbers.length,
  'queens' => (puzzle as QueensPuzzle).size,
  'loop' => (puzzle as LoopPuzzle).clues.length,
  'cipher' => (puzzle as CipherPuzzle).rows.length,
  'knights' => (puzzle as KnightsPuzzle).people,
  _ => 0,
};

// 要用最少步数的游戏在困难与专家档的最少步数（题库存好，服务器拿答案的步数比）：汉诺塔、冰面滑行、点灯按步数，推箱子按推的次数。
int? challengeMinimum(String game, Object? puzzle) => switch (game) {
  'hanoi' => hanoiMinMoves((puzzle as HanoiPuzzle).start, puzzle.target),
  'ice' => iceMinMoves(puzzle as IcePuzzle),
  'lights' => lightsSolve(puzzle as LightsPuzzle)!.length,
  'boxes' => boxesSolve(puzzle as BoxesPuzzle)!.pushes,
  _ => null,
};
