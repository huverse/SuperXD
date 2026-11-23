import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/app_services.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/page/academic_catalog.dart';
import 'package:superxd/page/academic_page.dart';
import 'package:superxd/page/sync_records_page.dart';
import 'package:superxd/page/account_dialogs.dart';
import 'package:superxd/page/app_account_page.dart';
import 'package:superxd/page/animated_branches.dart';
import 'package:superxd/page/login_page.dart';
import 'package:superxd/page/legal_page.dart';
import 'package:superxd/page/message_page.dart';
import 'package:superxd/page/section_pages.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/page/about_page.dart';
import 'package:superxd/page/account_page.dart';
import 'package:superxd/page/appearance_page.dart';
import 'package:superxd/page/quick_entry.dart';
import 'package:superxd/page/side_drawer.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/page/today_page.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_page.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 推入应用账号页（与教务各管各的，没登录教务也能进）：游乐场的挑战、私信、账号页与节日动画后的抽奖提示共用；联网偏好与删除游乐场与积分也在这页。
// 只在配了中转（有应用账号）时调。开发者的话与节日红包也在这页（人工决策见 page/section_pages.dart 的 MinePage 11-19 那条）。
void pushAppAccountPage(BuildContext context, AppServices services, {Future<bool> Function(Uint8List png)? saveRewardPicture}) => unawaited(Navigator.of(context, rootNavigator: true).push(CampusPageRoute<void>(
  builder: (context) => AppAccountPage(appAccounts: services.appAccounts!, diagnostics: services.diagnostics, network: services.network, leisure: services.leisure, notes: services.notes, festivals: services.festivals, saveRewardPicture: saveRewardPicture),
)));

// 路由表（组合根）：设备级服务都在 services 里（见 app_services.dart），百宝箱运行时与游乐场记录由外壳给好。
GoRouter buildRouter({required AppSession session, required AppServices services, required ToolboxRuntime toolbox, required PlaygroundStore playground, ValueListenable<bool>? splashGone, Future<bool> Function(Uint8List png)? saveRewardPicture, List<NavigatorObserver>? observers}) {
  final AppServices(:reminders, :social, :nearby, :updates, :developer, :logs, :paintings, :notes, :festivals, :appAccounts, :challenges, :unlocks, :autoSync, :health, :network, :features, :quickNav) = services;
  final void Function(BuildContext context)? openAccount = appAccounts == null ? null : (context) => pushAppAccountPage(context, services, saveRewardPicture: saveRewardPicture);
  final gateway = session.gateway;
  final tools = toolbox.modules;
  // 有自己页面的工具与子模块（规则见 toolbox_module.dart 的 toolboxRoutable）。
  final pages = toolboxRoutable(tools).toList();
  // 好友分享的卡片交给注册表里认得它的工具打开（页面层不依赖百宝箱，由这里接上；路由不认识具体工具页面）。
  void openVideo(BuildContext context, VideoShare video) {
    final page = toolboxTree(tools).map((tool) => tool.openShared?.call(video)).nonNulls.firstOrNull;
    if (page == null) return;
    Navigator.of(context, rootNavigator: true).push(CampusPageRoute<void>(builder: (_) => page));
  }
  final rootKey = GlobalKey<NavigatorState>();
  final generation = session.generation;
  // 课表页「去同步」：回到今天页、由今天页打开同步范围（人工决策见 today_page.dart 的 TodaySyncRequest）。
  final todaySync = TodaySyncRequest();
  late final GoRouter router;
  final academic = AcademicHost(
    gateway: gateway,
    isAccountCurrent: () => session.generation == generation && session.loggedIn,
    onSessionExpired: () => session.expire(generation),
    requestSync: (year) {
      todaySync.request(year: year);
      router.go('/today');
    },
    requestLogin: () => router.push('/switch-account'),
    reminders: reminders,
    social: social,
  );
  // 今天页侧栏与搜索的入口目录（人工决策见 page/side_drawer.dart）：从学业、百宝箱（含子模块与快捷入口）、游乐场的登记与几个设置页汇总，
  // 显隐同路由门禁（解锁、灰度）；不放底栏四个根页（底栏就有）。有路由的 id 就是路径，没有的写固定名字，发出后不改。
  void push(BuildContext context, Widget page) => unawaited(Navigator.of(context, rootNavigator: true).push(CampusPageRoute<void>(builder: (context) => page)));
  String sessionName() => switch (gateway.activeSession) {
    null => '',
    final account => account.name.isEmpty ? account.loginId : account.name,
  };
  List<QuickEntry> quickEntries() => [
    QuickEntry(id: '/academic', title: '学业', icon: CampusIcons.academic, group: '学业', keywords: const ['同步', '教务'], open: (context) => context.push('/academic')),
    for (final feature in academicFeatures) QuickEntry(id: feature.path, title: feature.title, icon: feature.icon, group: '学业', open: (context) => context.push(feature.path)),
    QuickEntry(id: '/academic/records', title: '同步记录', icon: CampusIcons.history, group: '学业', open: (context) => context.push('/academic/records')),
    QuickEntry(id: '/toolbox', title: '百宝箱', icon: CampusIcons.toolbox, group: '百宝箱', keywords: const ['工具'], open: (context) => context.push('/toolbox')),
    for (final tool in pages)
      if (toolboxRedirect(tools, toolboxPath(tool), unlocks: unlocks, features: features) == null) ...[
        QuickEntry(id: toolboxPath(tool), title: tool.name, icon: tool.icon, group: '百宝箱', keywords: _quickAliases[tool.id] ?? const [], open: (context) => context.push(toolboxPath(tool))),
        for (final shortcut in tool.shortcuts) QuickEntry(id: '${toolboxPath(tool)}/${shortcut.id}', title: shortcut.label, icon: shortcut.icon, group: '百宝箱', open: (context) => context.push('${toolboxPath(tool)}/${shortcut.id}')),
      ],
    QuickEntry(id: '/playground', title: '游乐场', icon: CampusIcons.playground, group: '游乐场', keywords: const ['游戏', '挑战', '积分'], open: (context) => context.push('/playground')),
    for (final game in playgroundCatalog)
      if (unlocks?.locked(playgroundUnlockId(game.id)) != true) QuickEntry(id: '/playground/${game.id}', title: game.name, icon: game.icon, group: '游乐场', open: (context) => context.push('/playground/${game.id}')),
    QuickEntry(id: 'appearance', title: '界面', icon: CampusIcons.palette, group: '设置', keywords: const ['字号', '配色', '字体', '深色', '壁纸', '玻璃'], open: (context) => push(context, const AppearancePage())),
    QuickEntry(id: 'account', title: '教务账号', icon: CampusIcons.account, group: '设置', keywords: const ['切换账号', '退出登录', '记住账号'], open: (context) => push(context, AccountPage(session: session, name: sessionName()))),
    if (openAccount != null) QuickEntry(id: 'app-account', title: '应用账号', icon: CampusIcons.mainAccount, group: '设置', keywords: const ['开发者的话', '红包', '联网', '恢复码'], open: openAccount),
    QuickEntry(id: 'about', title: '关于', icon: CampusIcons.info, group: '设置', keywords: const ['检查更新', '版本', '隐私政策', '用户协议', '开屏画作'], open: (context) => push(context, AboutPage(updates: updates, health: health, developer: developer, logs: logs, paintings: paintings))),
  ];
  final quick = QuickCatalog(entries: quickEntries, defaults: _quickDefaults, changes: [?unlocks?.changes, ?features?.changes]);
  router = GoRouter(
    navigatorKey: rootKey,
    observers: observers,
    initialLocation: '/boot',
    refreshListenable: session,
    redirect: (context, state) {
      final location = state.matchedLocation;
      if (!session.ready) return location == '/boot' ? null : '/boot';
      if (location == '/boot') return session.loggedIn ? '/today' : '/login';
      final atLogin = location == '/login';
      final legal = location.startsWith('/legal');
      // [人工决策-2026-09-27 20:12:08] 仅百宝箱及注册工具免教务登录，其他业务门禁不变。
      // 工具登记的快捷入口属于这个工具，同样免登录；子模块（生活下面的）同属百宝箱。
      final publicTool = location == '/toolbox' || pages.any((tool) => location == toolboxPath(tool) || tool.shortcuts.any((shortcut) => location == '${toolboxPath(tool)}/${shortcut.id}'));
      // [人工决策-2026-11-12 21:00:20] 游乐场的自由模式同百宝箱免教务登录（用户选定，补充 09-27 那条）：本机成绩属于设备，切换账号不丢。
      // 挑战模式要应用账号（以教务登录为登录方式之一），做好后在挑战页里自己要求登录，不在这里拦。
      // （11-15 起应用账号是自己的账号体系、与教务各管各的，人工决策见 domain/app_account.dart；挑战照旧在挑战页里要求登录。）
      final publicPlay = location == '/playground' || playgroundCatalog.any((game) => location == '/playground/${game.id}');
      if (!session.loggedIn && !atLogin && !legal && !publicTool && !publicPlay) return '/login';
      if (session.loggedIn && atLogin) return '/today';
      // 解锁（人工决策见服务端 src/modules/unlock/unlock_rules.ts）：锁着的游戏与隐藏的工具（含它的快捷入口）不让直接进，回到各自的首页。
      final segments = location.split('/');
      if (unlocks != null && segments.length >= 3 && segments[1] == 'playground' && unlocks.locked(playgroundUnlockId(segments[2]))) return '/playground';
      // 灰度中的工具同样：开关没开不让直接进（规则见 toolbox_page.dart 的 toolboxVisible）；子模块看不见回到上一层。
      return toolboxRedirect(tools, location, unlocks: unlocks, features: features);
    },
    routes: [
      GoRoute(
        path: '/boot',
        builder: (context, state) => const CampusBackground(child: Scaffold(backgroundColor: Colors.transparent, body: Center(child: CampusLoading(label: '正在恢复账号')))),
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: LoginPage(gateway: session.gateway, session: session, updates: updates, health: health, developer: developer, logs: logs, paintings: paintings)),
      ),
      GoRoute(
        path: '/switch-account',
        parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: LoginPage(gateway: session.gateway, session: session, switching: true)),
      ),
      GoRoute(
        path: '/legal/:kind',
        parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: LegalPage(privacy: state.pathParameters['kind'] == 'privacy')),
      ),
      GoRoute(path: '/toolbox', parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: ToolboxPage(runtime: toolbox, unlocks: unlocks, features: features))),
      // 父模块没给页面的（生活）由框架列出子模块。
      for (final tool in pages) GoRoute(path: toolboxPath(tool), parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: tool.builder?.call(context) ?? ToolboxPage(runtime: toolbox, parent: tool, unlocks: unlocks, features: features))),
      for (final tool in pages)
        for (final shortcut in tool.shortcuts) GoRoute(path: '${toolboxPath(tool)}/${shortcut.id}', parentNavigatorKey: rootKey,
          pageBuilder: (context, state) => campusPage(key: state.pageKey, child: shortcut.builder(context))),
      GoRoute(path: '/playground', parentNavigatorKey: rootKey,
        // 仅本机时没有挑战分段（人工决策见 domain/network_policy.dart 的 11-16 22:24:59 那条），自由模式照常。
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: ListenableBuilder(listenable: Listenable.merge([?network]), builder: (context, _) => PlaygroundPage(
          store: playground,
          games: playgroundCatalog,
          groups: playgroundGroups,
          challenges: network?.online == false ? null : challenges,
          unlocks: unlocks,
          // 挑战要应用账号：推入应用账号页。
          openAccount: openAccount,
        )))),
      for (final game in playgroundCatalog) GoRoute(path: '/playground/${game.id}', parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: PlaygroundGameHost(game: game, store: playground))),
      // 学业里各项数据的页面（课表、成绩）从学业功能登记生成（page/academic_catalog.dart）。
      for (final feature in academicFeatures) GoRoute(path: feature.path, parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: feature.builder(context, academic))),
      // 学业（人工决策见 page/academic_page.dart）：课表、成绩与同步的入口；同步记录也从系统通知「新出了几门成绩」点进来。
      GoRoute(
        path: '/academic', parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: AcademicPage(gateway: gateway, autoSync: autoSync, onSessionExpired: () => session.expire(generation), isAccountCurrent: () => session.generation == generation && session.loggedIn)),
      ),
      GoRoute(
        path: '/academic/records', parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: SyncRecordsPage(gateway: gateway, autoSync: autoSync, isAccountCurrent: () => session.generation == generation && session.loggedIn)),
      ),
      StatefulShellRoute(
        navigatorContainerBuilder: (context, shell, children) => AnimatedBranches(index: shell.currentIndex, children: children),
        pageBuilder: (context, state, navigationShell) => campusPage(key: state.pageKey, child: LegacyImportGate(session: session, child: ShellPage(
          navigationShell: navigationShell, social: social, notes: notes, revealed: splashGone,
          drawer: quickNav == null ? null : SideDrawerPanel(catalog: quick, nav: quickNav),
        ))),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/today', builder: (context, state) => TodayPage(gateway: gateway, onSessionExpired: () => session.expire(generation), isAccountCurrent: () => session.generation == generation && session.loggedIn, syncRequest: todaySync, autoSync: autoSync))]),
          StatefulShellBranch(routes: [GoRoute(path: '/service', builder: (context, state) => const ServicePage())]),
          StatefulShellBranch(routes: [GoRoute(path: '/message', builder: (context, state) => MessagePage(social: social, nearby: nearby, gateway: gateway, openVideo: openVideo, openAccount: openAccount))]),
          StatefulShellBranch(routes: [GoRoute(path: '/mine', builder: (context, state) => MinePage(session: session, updates: updates, health: health, developer: developer, logs: logs, paintings: paintings, notes: notes, appAccounts: appAccounts, openAppAccount: openAccount))]),
        ],
      ),
    ],
  );
  // 进了目录里登记的页面（从哪里进的都算，含侧栏、服务页与快捷入口）就记进侧栏的最近；没路由的设置页由侧栏打开时自己记。
  if (quickNav != null) {
    router.routerDelegate.addListener(() {
      if (router.routerDelegate.currentConfiguration.isEmpty) return;
      final location = router.state.matchedLocation;
      if (quickEntries().any((entry) => entry.id == location)) quickNav.visit(location);
    });
  }
  return router;
}

// 没编辑过常用时侧栏列这几个（看不见的跳过）。
const _quickDefaults = ['/schedule', '/grades', '/toolbox/chaoxing', '/toolbox/life/zhuli', '/toolbox/express', '/toolbox/short_video', '/playground'];

// 百宝箱各工具在搜索里的别名（按工具 id）。
const _quickAliases = {
  'short_video': ['去水印', '下载', '抖音', '短视频'],
  'chaoxing': ['签到', '超星'],
  'express': ['取件', '驿站', '拼多多'],
  'cinema': ['电影', '看片', '影视'],
  'life.zhuli': ['洗澡', '洗浴', '热水', '水控', '充值'],
};
