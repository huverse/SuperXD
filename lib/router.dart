import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/gateway/campus_gateway.dart';
import 'package:superxd/page/account_dialogs.dart';
import 'package:superxd/page/animated_branches.dart';
import 'package:superxd/page/login_page.dart';
import 'package:superxd/page/placeholder_pages.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/page/grades_page.dart';
import 'package:superxd/page/section_pages.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/page/today_page.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';

GoRouter buildRouter({required CampusGateway gateway, required AppSession session}) {
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
      if (!session.loggedIn && !atLogin && !legal) return '/login';
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
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: LegalPage(title: state.pathParameters['kind'] == 'privacy' ? '隐私政策' : '服务协议')),
      ),
      GoRoute(
        path: '/schedule',
        parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey, child: SchedulePage(gateway: gateway)),
      ),
      GoRoute(
        path: '/grades', parentNavigatorKey: rootKey,
        pageBuilder: (context, state) => campusPage(key: state.pageKey,
          child: GradesPage(gateway: gateway, isAccountCurrent: () => session.generation == generation && session.loggedIn, onLoginRequired: () => context.push('/switch-account'))),
      ),
      StatefulShellRoute(
        navigatorContainerBuilder: (context, shell, children) => AnimatedBranches(index: shell.currentIndex, children: children),
        pageBuilder: (context, state, navigationShell) => campusPage(key: state.pageKey, child: LegacyImportGate(session: session, child: ShellPage(navigationShell: navigationShell))),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/today', builder: (context, state) => TodayPage(gateway: gateway, onSessionExpired: () => session.expire(generation), isAccountCurrent: () => session.generation == generation && session.loggedIn))]),
          StatefulShellBranch(routes: [GoRoute(path: '/service', builder: (context, state) => const ServicePage())]),
          StatefulShellBranch(routes: [GoRoute(path: '/message', builder: (context, state) => const MessagePage())]),
          StatefulShellBranch(routes: [GoRoute(path: '/mine', builder: (context, state) => MinePage(gateway: gateway, session: session))]),
        ],
      ),
    ],
  );
}
