import 'package:flutter/widgets.dart';

import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle_rules.dart';

// 游乐场按「板块 → 子类 → 游戏」三级组织（同应用商店的分类 → 子分类 → 应用）：首页按板块分页、板块里按子类分组，不把所有游戏混成一张表。
// 三级的 id 发出后都不改：本机记录、以后的挑战题库与积分都按 id 认。只在 playground_catalog.dart 一处登记。

// 板块：大类，如益智；以后再加休闲、棋牌等。只有一个板块时首页不显示板块切换。
class PlaygroundSection {
  const PlaygroundSection({required this.id, required this.name, required this.icon});
  final String id;
  final String name;
  final IconData icon;
}

// 子类：板块里按玩法分的组，首页按它分段。
class PlaygroundGroup {
  const PlaygroundGroup({required this.id, required this.name, required this.section});
  final String id;
  final String name;
  final PlaygroundSection section;
}

// 自由模式从什么时候开始计时（[人工决策-2026-11-17 20:13:19] 用户选「推理类题一出现就计时」）。挑战模式以服务器计时为准，不看它。
enum PlayClock {
  // 题一出现就计时（默认）：题面全摊在眼前、看题就能开始推理或规划的游戏，不然可以不碰棋盘先想好，成绩只剩点几下的时间。
  sight,
  // 第一下才计时：扫雷（用户定照旧从第一下算）。
  firstMove,
  // 对局页自己的「开始」才计时：开始前看不到题、拼手速或记忆的游戏（舒尔特开局盖住、记忆闪光点了才亮），不套「快得不正常」的门槛。
  start,
}

// 一个游戏：名字、一句话玩法（首页卡片上）、玩法说明（对局页「玩法」里）、图标、所在子类与对局页。
// challengeable：服务器能不能核对这个游戏的答案。拼手速（舒尔特方格）与物理模拟（画线入杯）的结果服务器复现不了，只进自由模式。
// timeInTenths：用时写到 0.1 秒（几秒就完、拼手速的游戏，如舒尔特方格）：首页卡片的最好成绩与结果弹层按它选 playDuration 的写法，对局中的走表照旧按秒。
// clock：自由模式从什么时候开始计时（见 PlayClock）。
class PlaygroundGame {
  const PlaygroundGame({
    required this.id,
    required this.name,
    required this.summary,
    required this.howToPlay,
    required this.icon,
    required this.group,
    required this.builder,
    this.challengeable = true,
    this.timeInTenths = false,
    this.clock = PlayClock.sight,
  });
  final String id;
  final String name;
  final String summary;
  final String howToPlay;
  final IconData icon;
  final PlaygroundGroup group;
  final bool challengeable;
  final bool timeInTenths;
  final PlayClock clock;
  // 对局页：拿到自己的登记项（名字、玩法说明）与本机记录；挑战里的一关另给 challenge（题面是服务器给的，不出题、不记本机成绩）；
  // 自由模式从外壳进来时另给 first（外壳在后台出好的第一道题，画线入杯与舒尔特不备、为空）。
  final Widget Function(BuildContext context, PlaygroundGame game, PlaygroundStore store, PlayChallenge? challenge, PlayFirst? first) builder;
}

// 对局页外壳在后台 isolate 里出好的第一道题（人工决策见 playground_page.dart 的 PlaygroundGameHost）：种子、档位与题；档位和对局页这次的档对上才用。
typedef PlayFirst = ({int seed, PuzzleTier tier, PuzzleDraw<Object?, Object?> draw});
