import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/app_services.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/application/account_diagnostics.dart';
import 'package:superxd/application/app_accounts.dart';
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
import 'package:superxd/page/today_page.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_page.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 推入应用账号页（与教务各管各的，没登录教务也能进）：游乐场的挑战、私信与节日动画后的抽奖提示共用。
void pushAppAccountPage(BuildContext context, AppAccounts appAccounts, AccountDiagnostics? diagnostics) =>
    unawaited(Navigator.of(context, rootNavigator: true).push(CampusPageRoute<void>(builder: (context) => AppAccountPage(appAccounts: appAccounts, diagnostics: diagnostics))));

// 路由表（组合根）：设备级服务都在 services 里（见 app_services.dart），百宝箱运行时与游乐场记录由外壳给好。
GoRouter buildRouter({required AppSession session, required AppServices services, required ToolboxRuntime toolbox, required PlaygroundStore playground, ValueListenable<bool>? splashGone, Future<bool> Function(Uint8List png)? saveRewardPicture, List<NavigatorObserver>? observers}) {
  final AppServices(:leisure, :reminders, :social, :updates, :developer, :logs, :paintings, :notes, :festivals, :appAccounts, :diagnostics, :challenges, :unlocks, :autoSync) = services;
  final gateway = session.gateway;
  final tools = toolbox.modules;
  // 好友分享的卡片交给注册表里认得它的工具打开（页面层不依赖百宝箱，由这里接上；路由不认识具体工具页面）。
  void openVideo(BuildContext context, VideoShare video) {
    final page = tools.map((tool) => tool.openShared?.call(video)).nonNulls.firstOrNull;
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
  return router = GoRouter(
    navigatorKey: rootKey,
    observers: observers,
    initialLocation: '/boot',
    refreshListenable: leisure == null ? session : Listenable.merge([session, leisure]),
    redirect: (context, state) {
      final location = state.matchedLocation;
      if (!session.ready) return location == '/boot' ? null : '/boot';
      if (location == '/boot') return session.loggedIn ? '/today' : '/login';
      final atLogin = location == '/login';
      final legal = location.startsWith('/legal');
      // [人工决策-2026-09-27 20:12:08] 仅百宝箱及注册工具免教务登录，其他业务门禁不变。
      // 工具登记的快捷入口属于这个工具，同样免登录。
      final publicTool = location == '/toolbox' || tools.any((tool) => location == '/toolbox/${tool.id}' || tool.shortcuts.any((shortcut) => location == '/toolbox/${tool.id}/${shortcut.id}'));
      // [人工决策-2026-11-12 21:00:20] 游乐场的自由模式同百宝箱免教务登录（用户选定，补充 09-27 那条）：本机成绩属于设备，切换账号不丢。
      // 挑战模式要应用账号（以教务登录为登录方式之一），做好后在挑战页里自己要求登录，不在这里拦。
      // （11-15 起应用账号是自己的账号体系、与教务各管各的，人工决策见 domain/app_account.dart；挑战照旧在挑战页里要求登录。）
      final publicPlay = location == '/playground' || playgroundCatalog.any((game) => location == '/playground/${game.id}');
      // 娱乐与积分关着（人工决策见 domain/leisure.dart）：游乐场与游戏都进不去，回到服务页（没登录教务回登录页）。
      if (leisure?.enabled == false && location.startsWith('/playground')) return session.loggedIn ? '/service' : '/login';
      if (!session.loggedIn && !atLogin && !legal && !publicTool && !publicPlay) return '/login';
      if (session.loggedIn && atLogin) return '/today';
      // 解锁（人工决策见服务端 src/modules/unlock/unlock_rules.ts）：锁着的游戏与隐藏的工具（含它的快捷入口）不让直接进，回到各自的首页。
      final segments = location.split('/');
      if (unlocks != null && segments.length >= 3) {
        final lock = switch (segments[1]) {
          'playground' => playgroundUnlockId(segments[2]),
          'toolbox' => toolboxUnlockId(segments[2]),
          _ => null,
        };
        if (lock != null && unlocks.locked(lock)) return '/${segments[1]}';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/boot',
        builder: (context, state) => const CampusBackground(child: Scaffold(backgroundColor: Colors.transparent, body: Center(child: CampusLoading(label: '正在恢复账号')))),
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: LoginPage(gateway: session.gateway, session: session, updates: updates, developer: developer, logs: logs, paintings: paintings, leisure: leisure)),
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
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: ToolboxPage(runtime: toolbox, unlocks: unlocks))),
      for (final tool in tools) GoRoute(path: '/toolbox/${tool.id}', parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: tool.builder(context))),
      for (final tool in tools)
        for (final shortcut in tool.shortcuts) GoRoute(path: '/toolbox/${tool.id}/${shortcut.id}', parentNavigatorKey: rootKey,
          pageBuilder: (context, state) => campusPage(key: state.pageKey, child: shortcut.builder(context))),
      GoRoute(path: '/playground', parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: PlaygroundPage(
          store: playground,
          games: playgroundCatalog,
          groups: playgroundGroups,
          challenges: challenges,
          unlocks: unlocks,
          // 挑战要应用账号：推入应用账号页。
          openAccount: appAccounts == null ? null : (context) => pushAppAccountPage(context, appAccounts, diagnostics),
        ))),
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
        pageBuilder: (context, state, navigationShell) => campusPage(key: state.pageKey, child: LegacyImportGate(session: session, child: ShellPage(navigationShell: navigationShell, social: social, notes: notes, revealed: splashGone))),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/today', builder: (context, state) => TodayPage(gateway: gateway, onSessionExpired: () => session.expire(generation), isAccountCurrent: () => session.generation == generation && session.loggedIn, syncRequest: todaySync, autoSync: autoSync))]),
          StatefulShellBranch(routes: [GoRoute(path: '/service', builder: (context, state) => ServicePage(leisure: leisure))]),
          StatefulShellBranch(routes: [GoRoute(path: '/message', builder: (context, state) => MessagePage(social: social, gateway: gateway, openVideo: openVideo, openAccount: appAccounts == null ? null : (context) => pushAppAccountPage(context, appAccounts, diagnostics)))]),
          StatefulShellBranch(routes: [GoRoute(path: '/mine', builder: (context, state) => MinePage(session: session, social: social, updates: updates, developer: developer, logs: logs, paintings: paintings, notes: notes, festivals: festivals, appAccounts: appAccounts, diagnostics: diagnostics, leisure: leisure, saveRewardPicture: saveRewardPicture))]),
        ],
      ),
    ],
  );
}
