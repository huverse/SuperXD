import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/page/account_dialogs.dart';
import 'package:superxd/page/animated_branches.dart';
import 'package:superxd/page/login_page.dart';
import 'package:superxd/page/legal_page.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/page/grades_page.dart';
import 'package:superxd/page/message_page.dart';
import 'package:superxd/page/section_pages.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/page/today_page.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/toolbox/short_video/short_video_page.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

GoRouter buildRouter({required CampusGateway gateway, required AppSession session, required ToolboxRuntime toolbox, CampusReminders? reminders, SocialService? social}) {
  final tools = toolboxCatalog(toolbox);
  // 好友分享的视频在百宝箱短视频页打开并直接解析（页面层不依赖百宝箱，由这里接上）。
  void openVideo(BuildContext context, VideoShare video) => Navigator.of(context, rootNavigator: true).push(CampusPageRoute<void>(
    builder: (_) => ShortVideoPage(runtime: toolbox, initialInput: video.sourceUrl, autoParse: true),
  ));
  final rootKey = GlobalKey<NavigatorState>();
  final generation = session.generation;
  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: '/boot',
    refreshListenable: session,
    redirect: (context, state) {
      final location = state.matchedLocation;
      if (!session.ready) return location == '/boot' ? null : '/boot';
      if (location == '/boot') return session.loggedIn ? '/today' : '/login';
      final atLogin = location == '/login';
      final legal = location.startsWith('/legal');
      // [人工决策-2026-09-27 20:12:08] 仅百宝箱及注册工具免教务登录，其他业务门禁不变。
      final publicTool = location == '/toolbox' || tools.any((tool) => location == '/toolbox/${tool.id}');
      if (!session.loggedIn && !atLogin && !legal && !publicTool) return '/login';
      if (session.loggedIn && atLogin) return '/today';
      return null;
    },
    routes: [
      GoRoute(
        path: '/boot',
        builder: (context, state) => const CampusBackground(child: Scaffold(backgroundColor: Colors.transparent, body: Center(child: CampusLoading(label: '正在恢复账号')))),
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: LoginPage(gateway: session.gateway, session: session)),
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
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: ToolboxPage(runtime: toolbox))),
      for (final tool in tools) GoRoute(path: '/toolbox/${tool.id}', parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: tool.builder(context))),
      GoRoute(
        path: '/schedule',
        parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: SchedulePage(gateway: gateway, reminders: reminders, social: social)),
      ),
      GoRoute(
        path: '/grades', parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey,
          child: GradesPage(gateway: gateway, isAccountCurrent: () => session.generation == generation && session.loggedIn, onLoginRequired: () => context.push('/switch-account'))),
      ),
      StatefulShellRoute(
        navigatorContainerBuilder: (context, shell, children) => AnimatedBranches(index: shell.currentIndex, children: children),
        pageBuilder: (context, state, navigationShell) => campusPage(key: state.pageKey, child: LegacyImportGate(session: session, child: ShellPage(navigationShell: navigationShell, social: social))),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/today', builder: (context, state) => TodayPage(gateway: gateway, onSessionExpired: () => session.expire(generation), isAccountCurrent: () => session.generation == generation && session.loggedIn))]),
          StatefulShellBranch(routes: [GoRoute(path: '/service', builder: (context, state) => const ServicePage())]),
          StatefulShellBranch(routes: [GoRoute(path: '/message', builder: (context, state) => MessagePage(social: social, gateway: gateway, openVideo: openVideo))]),
          StatefulShellBranch(routes: [GoRoute(path: '/mine', builder: (context, state) => MinePage(gateway: gateway, session: session, social: social))]),
        ],
      ),
    ],
  );
}
