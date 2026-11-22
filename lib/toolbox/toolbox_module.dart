import 'dart:io';

import 'package:flutter/material.dart';

import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/toolbox/download/toolbox_download_manager.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_store.dart';

// 框架给工具服务的公共能力：本工具可用的目录、百宝箱库（同意记录等）、下载管理与自建中转地址（没配时为空）。
class ToolboxServiceContext {
  const ToolboxServiceContext({required this.base, required this.store, required this.downloads, this.relayUrl});
  final Directory base;
  final ToolboxStore store;
  final ToolboxDownloadManager downloads;
  final Uri? relayUrl;
}

// 工具的常用功能快捷入口：长按应用图标的菜单与「添加到桌面」都按它生成，点了直达 builder 给的页面
// （路由 /toolbox/工具 id/入口 id，同工具页一样免教务登录）。id 在工具内唯一且不要改（桌面上的快捷方式按它找回页面），
// label 是菜单与桌面上的名字，icon 画成快捷方式的图标。
class ToolboxShortcut {
  const ToolboxShortcut({required this.id, required this.label, required this.icon, required this.builder});
  final String id;
  final String label;
  final IconData icon;
  final WidgetBuilder builder;
}

// 一个工具的全部登记：名称、图标、页面、按需资源、自己的服务与快捷入口都写在这一处，增删工具只改注册表。
// openService 不为空表示工具有自己的本机数据，百宝箱首页据此给出「清除数据」（经 ToolboxService.clearData）。
// [人工决策-2026-11-22 18:46:09] 子模块（用户选「框架统一子模块」，没选「生活与电影院各管各」「子模块直接上百宝箱首页」）：
// 工具可以带子模块 children，子模块和工具是同一种登记（名称、图标、页面、服务与清除数据、灰度开关、解锁、快捷入口），
// 路由、显示与隐藏、清除数据、快捷入口都由框架按注册表生成，以后加子模块只在注册表加一项。子模块的 id 写成「父 id.子 id」（如 life.zhuli），
// 路由按点分层（/toolbox/life/zhuli），服务、同意记录、解锁（toolbox.life.zhuli）都用这同一个 id，发出后不改。两种摆法：
// 父模块不给 builder（生活）：框架用百宝箱首页同一套卡片列出子模块，子模块各是一页、有自己的路由，一个看得见的子模块都没有时父模块不出现；
// 父模块给了 builder（电影院）：自己在页面里摆子模块（如顶部分段），子模块是页面里的一段、没有自己的路由，不登记服务、资源与快捷入口。
class ToolboxModule {
  const ToolboxModule({
    required this.id,
    required this.name,
    required this.icon,
    this.builder,
    this.resource,
    this.openService,
    this.clearedData = '',
    this.openShared,
    this.shortcuts = const [],
    this.flag,
    this.children = const [],
  });
  final String id;
  final String name;
  final IconData icon;
  // 为空：由框架列出子模块的父模块（见类上的说明）。
  final WidgetBuilder? builder;
  final ToolboxResource? resource;
  final Future<ToolboxService> Function(ToolboxServiceContext context)? openService;
  // 「清除数据」确认里说清会删掉什么（各工具的数据不同，不能用一句通用话），登记了 openService 的工具必须给。
  final String clearedData;
  // 好友分享的卡片由哪个工具打开：认得这张卡就返回要推入的页面，不认得返回空；组合根按注册表找，不直接认识工具页面。
  final Widget? Function(ShareCard card)? openShared;
  final List<ToolboxShortcut> shortcuts;
  // 灰度中的工具：登记了开关的只在开关开着时显示入口、能进路由（domain/feature_flags.dart 登记，规则见 toolbox_page.dart 的 toolboxVisible）。
  final FeatureFlag? flag;
  final List<ToolboxModule> children;
}

// 模块的页面路径：id 里的点是层级（life.zhuli → /toolbox/life/zhuli）。
String toolboxPath(ToolboxModule module) => '/toolbox/${module.id.replaceAll('.', '/')}';

// 注册表里的全部模块，先父后子。
Iterable<ToolboxModule> toolboxTree(Iterable<ToolboxModule> modules) sync* {
  for (final module in modules) {
    yield module;
    yield* toolboxTree(module.children);
  }
}

// 有自己路由的模块：顶层工具，加上由框架列出子模块的父模块下面的子模块；自己摆子模块的父模块（电影院）的子模块不算。
Iterable<ToolboxModule> toolboxRoutable(Iterable<ToolboxModule> modules) sync* {
  for (final module in modules) {
    yield module;
    if (module.builder == null) yield* toolboxRoutable(module.children);
  }
}

// 清除数据会删到的模块：自己与子模块里登记了服务的那些。
Iterable<ToolboxModule> toolboxClearable(ToolboxModule module) => toolboxTree([module]).where((each) => each.openService != null);

// 「清除数据」确认里写的内容：父模块没有自己的数据时，按子模块逐个写。
String toolboxClearedData(ToolboxModule module) => module.openService != null
    ? module.clearedData
    : [for (final child in module.children) if (toolboxClearable(child).isNotEmpty) '${child.name}的${toolboxClearedData(child)}'].join('；');
