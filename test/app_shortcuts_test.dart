import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;

import 'package:superxd/app_shortcuts.dart';
import 'package:superxd/domain/app_shortcut.dart';
import 'package:superxd/toolbox/toolbox_module.dart';

class _FakePort implements AppShortcutPort {
  final published = <List<AppShortcut>>[];
  final pinned = <AppShortcut>[];
  final launchEvents = StreamController<String>.broadcast();
  bool pinSupported = true;

  @override
  Future<void> publish(List<AppShortcut> shortcuts) async => published.add(shortcuts);

  @override
  Future<bool> pin(AppShortcut shortcut) async {
    pinned.add(shortcut);
    return pinSupported;
  }

  @override
  Future<String?> takeLaunch() async => null;

  @override
  Stream<String> get launches => launchEvents.stream;
}

final _tools = [
  ToolboxModule(
    id: 'demo',
    name: '合成工具',
    icon: Icons.build,
    builder: (context) => const Text('工具页'),
    shortcuts: [ToolboxShortcut(id: 'quick', label: '合成入口', icon: Icons.qr_code, builder: (context) => const Text('入口页'))],
  ),
  ToolboxModule(id: 'plain', name: '没有入口的工具', icon: Icons.build, builder: (context) => const Text('另一个工具')),
];

void main() {
  testWidgets('注册表里登记的入口都发布出去（id 是工具 id.入口 id，图标是自适应图标规格的 PNG）；添加到桌面用同一份；后台点了入口记下要去的页面，认不出的 id 不记', (tester) async {
    final port = _FakePort();
    final shortcuts = AppShortcuts(port: port, tools: _tools, pixelRatio: 2);
    addTearDown(shortcuts.dispose);
    await tester.runAsync(shortcuts.start);
    final published = port.published.single;
    expect([for (final shortcut in published) shortcut.id], ['demo.quick']);
    expect(published.single.label, '合成入口');
    final icon = img.decodePng(published.single.icon)!;
    expect((icon.width, icon.height), (216, 216));

    port.pinSupported = false;
    expect(await tester.runAsync(() => shortcuts.pin('demo', 'quick')), isFalse);
    expect(port.pinned.single.id, 'demo.quick');

    port.launchEvents.add('demo.quick');
    await tester.pump();
    expect(shortcuts.pending.value, '/toolbox/demo/quick');
    shortcuts.pending.value = null;
    port.launchEvents.add('gone.quick');
    await tester.pump();
    expect(shortcuts.pending.value, isNull, reason: '以后删掉了的入口还留在桌面上，照常打开应用');
  });

  testWidgets('子模块的入口：id 是「子模块 id.入口 id」（life.demo.scan），页面在子模块路径下；自己摆子模块的父模块（电影院那种）的子模块不发布入口', (tester) async {
    final port = _FakePort();
    ToolboxShortcut shortcut(String id) => ToolboxShortcut(id: id, label: '入口$id', icon: Icons.qr_code, builder: (context) => const Text('入口页'));
    final shortcuts = AppShortcuts(
      port: port,
      tools: [
        ToolboxModule(id: 'life', name: '合成生活', icon: Icons.home, children: [ToolboxModule(id: 'life.demo', name: '合成子模块', icon: Icons.build, builder: (context) => const Text('子模块页'), shortcuts: [shortcut('scan')])]),
        ToolboxModule(id: 'tabs', name: '自己摆的', icon: Icons.build, builder: (context) => const Text('父页'), children: [ToolboxModule(id: 'tabs.one', name: '一段', icon: Icons.build, builder: (context) => const Text('一段'), shortcuts: [shortcut('hidden')])]),
      ],
      pixelRatio: 1,
    );
    addTearDown(shortcuts.dispose);
    await tester.runAsync(shortcuts.start);
    expect([for (final each in port.published.single) each.id], ['life.demo.scan']);
    await tester.runAsync(() => shortcuts.pin('life.demo', 'scan'));
    expect(port.pinned.single.id, 'life.demo.scan');
    port.launchEvents.add('life.demo.scan');
    await tester.pump();
    expect(shortcuts.pending.value, '/toolbox/life/demo/scan');
  });

  testWidgets('入口要去的页面：会话恢复好之前（启动页）不动；不在首页时回首页与推入同一帧做完、只走一次转场，返回回到首页', (tester) async {
    Widget page(String text) => Scaffold(body: Text(text));
    final router = GoRouter(initialLocation: '/boot', routes: [
      GoRoute(path: '/boot', builder: (context, state) => page('启动页')),
      GoRoute(path: '/today', builder: (context, state) => page('今天')),
      GoRoute(path: '/other', builder: (context, state) => page('别的页')),
      GoRoute(path: '/toolbox/demo/quick', builder: (context, state) => page('入口页')),
    ]);
    addTearDown(router.dispose);
    final pending = ValueNotifier<String?>('/toolbox/demo/quick');
    addTearDown(pending.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    openShortcut(router, pending, home: '/today');
    await tester.pumpAndSettle();
    expect(find.text('启动页'), findsOneWidget);
    expect(pending.value, '/toolbox/demo/quick');

    router.go('/other');
    await tester.pumpAndSettle();
    openShortcut(router, pending, home: '/today');
    expect(pending.value, isNull, reason: '回首页与推入在同一帧里做完');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('入口页'), findsOneWidget, reason: '第一段转场就是推入，不先退回首页、退完再推（11-23 全应用切换走查）');
    await tester.pumpAndSettle();
    expect(find.text('入口页'), findsOneWidget);
    expect(find.text('别的页'), findsNothing);
    expect(pending.value, isNull);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('今天'), findsOneWidget);
  });
}
