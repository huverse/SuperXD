import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/page/animated_branches.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/theme/status_bar_scroll.dart';
import 'package:superxd/theme/campus_theme.dart';

class _Probe extends StatefulWidget {
  const _Probe();
  static var created = 0;
  static var inset = -1.0;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.created++;
  }

  @override
  Widget build(BuildContext context) {
    _Probe.inset = MediaQuery.paddingOf(context).bottom;
    return const SizedBox.expand(key: ValueKey('probe'));
  }
}

GoRouter _router() => GoRouter(initialLocation: '/0', routes: [
  StatefulShellRoute.indexedStack(
    builder: (context, state, shell) => ShellPage(navigationShell: shell),
    branches: [for (var index = 0; index < 4; index++) StatefulShellBranch(routes: [GoRoute(path: '/$index', builder: (context, state) => const _Probe())])],
  ),
]);

void main() {
  setUp(() { _Probe.created = 0; _Probe.inset = -1; });

  testWidgets('内容层铺到屏幕底部并以底栏占位作为底部安全区', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp.router(theme: campusTheme(), routerConfig: _router()));
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(find.byKey(const ValueKey('probe'))).dy, 800);
    // 底栏72+8，距安全区12，上方留12；测试视图无系统安全区。
    expect(_Probe.inset, 72 + 8 + 12 + 12);
    expect(find.byKey(const ValueKey('navigation-capsule')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('键盘弹出时隐藏底栏、恢复原安全区且不重建分支页面', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(MaterialApp.router(theme: campusTheme(), routerConfig: _router()));
    await tester.pumpAndSettle();
    expect(_Probe.created, 1);
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('navigation-capsule')), findsNothing);
    expect(_Probe.inset, 0);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('navigation-capsule')), findsOneWidget);
    expect(_Probe.created, 1);
    expect(tester.takeException(), isNull);
  });

  // [人工决策] 见 lib/theme/native_glass.dart（系统底栏挂在 Flutter 视图上）与 shell_page.dart、animated_branches.dart（10-27 直接切、再点当前项）。
  testWidgets('iOS：内容按系统报来的底栏总高留位置，点底栏直接切过去，再点当前项回到这一栏首页或滚回顶部', (tester) async {
    const tabBar = MethodChannel('superxd/tab_bar');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(tabBar, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(tabBar, null));
    Future<void> native(String method, Object? arguments) async {
      await messenger.handlePlatformMessage('superxd/tab_bar', const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)), (_) {});
      await tester.pump();
    }
    final list = ScrollController();
    addTearDown(list.dispose);
    final router = GoRouter(initialLocation: '/0', routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => ShellPage(navigationShell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/0', builder: (context, state) => const _Probe(), routes: [GoRoute(path: 'detail', builder: (context, state) => const Text('详情'))])]),
          StatefulShellBranch(routes: [GoRoute(path: '/1', builder: (context, state) => ListView(controller: list, children: [for (var index = 0; index < 60; index++) SizedBox(height: 48, child: Text('第$index行'))]))]),
        ],
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(theme: campusTheme(), routerConfig: router, builder: (context, child) => CampusStatusBarScroll(child: child!)));
    await tester.pumpAndSettle();
    // 量到之前按 49 加底部安全区（测试里为 0）留位置，原生报来总高后照它留；底栏上方都多留 12（同安卓，回今天胶囊与底栏的间隙）。
    expect(_Probe.inset, 49 + 12);
    await native('height', 83.0);
    expect(_Probe.inset, 83 + 12);
    // 提示条（SnackBar 出在最外层的壳 Scaffold 里）整个浮在系统底栏上面，不被挡住。
    ScaffoldMessenger.of(tester.element(find.byKey(const ValueKey('probe')))).showSnackBar(const SnackBar(content: Text('已复制')));
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(find.text('已复制')).dy, lessThanOrEqualTo(tester.getSize(find.byType(MaterialApp)).height - 83));
    ScaffoldMessenger.of(tester.element(find.byKey(const ValueKey('probe')))).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await native('select', 1);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/1');
    expect(tester.getTopLeft(find.text('第0行')).dx, 0);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(list.offset, greaterThan(0));
    await native('select', 1);
    await tester.pumpAndSettle();
    expect(list.offset, 0);
    await native('select', 0);
    router.go('/0/detail');
    await tester.pumpAndSettle();
    expect(find.text('详情'), findsOneWidget);
    await native('select', 0);
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/0');
    expect(find.text('详情'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  // [人工决策] 见 lib/page/animated_branches.dart：iOS 上切分支直接到位，安卓照旧两页并排滑动。
  testWidgets('切分支：iOS 直接到位，安卓并排滑动', (tester) async {
    Widget branches(int index) => MaterialApp(home: AnimatedBranches(index: index, children: const [Text('第一栏'), Text('第二栏')]));
    await tester.pumpWidget(branches(0));
    await tester.pumpWidget(branches(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    if (debugDefaultTargetPlatformOverride == TargetPlatform.iOS) {
      expect(tester.getTopLeft(find.text('第二栏')).dx, 0);
      expect(find.text('第一栏'), findsNothing);
    } else {
      expect(tester.getTopLeft(find.text('第二栏')).dx, greaterThan(0));
      expect(find.text('第一栏'), findsOneWidget);
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('第二栏')).dx, 0);
  }, variant: const TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));
}
