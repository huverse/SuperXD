import 'package:flutter/widgets.dart';

import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/playground_store.dart';

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

// 一个游戏：名字、一句话玩法（首页卡片上）、玩法说明（对局页「玩法」里）、图标、所在子类与对局页。
// challengeable：服务器能不能核对这个游戏的答案。拼手速（舒尔特方格）与物理模拟（画线入杯）的结果服务器复现不了，只进自由模式。
// timeInTenths：用时写到 0.1 秒（几秒就完、拼手速的游戏，如舒尔特方格）：首页卡片的最好成绩与结果弹层按它选 playDuration 的写法，对局中的走表照旧按秒。
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
  });
  final String id;
  final String name;
  final String summary;
  final String howToPlay;
  final IconData icon;
  final PlaygroundGroup group;
  final bool challengeable;
  final bool timeInTenths;
  // 对局页：拿到自己的登记项（名字、玩法说明）与本机记录；挑战里的一关另给 challenge（题面是服务器给的，不出题、不记本机成绩）。
  final Widget Function(BuildContext context, PlaygroundGame game, PlaygroundStore store, PlayChallenge? challenge) builder;
}
