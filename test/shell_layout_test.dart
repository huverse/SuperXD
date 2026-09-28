import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/page/shell_page.dart';
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
}
