import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_probe.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/app_moments.dart';
import 'package:superxd/application/app_updates.dart';
import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/application/festivals.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/developer_note.dart';
import 'package:superxd/domain/festival.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/domain/unlock.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/local/developer_note_memory.dart';
import 'package:superxd/local/festival_memory.dart';
import 'package:superxd/page/festival/festival_catalog.dart';
import 'package:superxd/page/festival/festival_stage.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/app_shortcut.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/local/developer_settings.dart';
import 'package:superxd/local/diagnostic_log.dart';
import 'package:superxd/page/about_page.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/local/legal_notice_memory.dart';
import 'package:superxd/page/legal_page.dart';
import 'package:superxd/page/today_page.dart';
import 'package:superxd/app_lifecycle.dart';
import 'package:superxd/app_services.dart';
import 'package:superxd/app_shell.dart';
import 'package:superxd/page/animated_branches.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/page/message_page.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/page/account_page.dart';
import 'package:superxd/page/app_account_page.dart';
import 'package:superxd/page/login_page.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/application/leisure.dart';
import 'package:superxd/local/leisure_memory.dart';
import 'package:superxd/page/section_pages.dart';
import 'package:superxd/page/leisure_page.dart';
import 'package:superxd/playground/playground_page.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_page.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/express/express_page.dart';
import 'package:superxd/toolbox/express/express_service.dart';
import 'package:superxd/toolbox/express/express_vault.dart';
import 'package:superxd/toolbox/short_video/short_video_page.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'app_update_fakes.dart';
import 'toolbox_test_support.dart';

void main() {
  testWidgets('百宝箱免教务登录，但课表门禁仍有效', (tester) async {
    final fixture = ToolboxFixture();
    await tester.runAsync(fixture.initialize);
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway); await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(toolbox: fixture.runtime)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('百宝箱'));
    await tester.pumpAndSettle();
    expect(find.byType(ToolboxPage), findsOneWidget);
    await tester.tap(find.text('视频解析'));
    for(var tick=0;tick<100&&find.byType(TextField).evaluate().isEmpty;tick++){
      await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:10)));
      await tester.pump(const Duration(milliseconds:16));
    }
    await tester.pumpAndSettle();
    expect(find.byType(ShortVideoPage), findsOneWidget);
    GoRouter.of(tester.element(find.byType(ShortVideoPage))).go('/schedule');
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(SchedulePage), findsNothing);
    for (final title in ['用户协议', '隐私政策']) {
      await tester.tap(find.text(title)); await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(find.textContaining('待替换'), findsNothing);
      await tester.tap(find.byTooltip('返回')); await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.runAsync(fixture.close);
  });

  // 人工决策见 router.dart 的门禁（游乐场自由模式免登录）。
  testWidgets('游乐场自由模式免教务登录：登录页进得去、能开游戏，课表门禁照旧', (tester) async {
    final fixture = ToolboxFixture();
    await tester.runAsync(fixture.initialize);
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway); await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(toolbox: fixture.runtime, playground: PlaygroundStore.memory())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('游乐场'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaygroundPage), findsOneWidget);
    // 游戏多了首页要滚动，列表按需构建：先滚到汉诺塔再点。
    await tester.scrollUntilVisible(find.text('汉诺塔'), 200, scrollable: find.descendant(of: find.byType(PlaygroundPage), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('汉诺塔'));
    await tester.pumpAndSettle();
    expect(find.byType(HanoiPage), findsOneWidget);
    GoRouter.of(tester.element(find.byType(HanoiPage))).go('/schedule');
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(SchedulePage), findsNothing);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.runAsync(fixture.close);
  });

  // 娱乐与积分的开关（人工决策见 domain/leisure.dart）。
  testWidgets('娱乐与积分关着时登录页没有游乐场入口，直接跳过去回登录页', (tester) async {
    final fixture = ToolboxFixture();
    await tester.runAsync(fixture.initialize);
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway); await session.restore();
    final leisure = Leisure(memory: FileLeisureMemory.memory(enabled: false), clearLocal: () async {});
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(toolbox: fixture.runtime, playground: PlaygroundStore.memory(), leisure: leisure)));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('游乐场'), findsNothing);
    expect(find.text('百宝箱'), findsOneWidget);
    GoRouter.of(tester.element(find.byType(LoginPage))).go('/playground/hanoi');
    await tester.pumpAndSettle();
    expect(find.byType(HanoiPage), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.runAsync(fixture.close);
  });

  // 11-16 用户的 OPPO 简化档底栏整块画黑（人工决策见 theme/campus_glass_tier.dart）：自检截到画坏就把这台手机改成「关闭」并提示，栏改实色。
  testWidgets('玻璃显示自检截到底栏整块画黑：改成关闭并提示，栏不再是玻璃', (tester) async {
    debugResetCampusGlassProbe();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    campusGlassReady.value = true;
    addTearDown(() => campusGlassReady.value = false);
    campusGlassProbe = (area) async => .99;
    addTearDown(() => campusGlassProbe = null);
    final display = DisplaySettings.memory();
    await display.setGlassMode('reduced');
    final session = AppSession(_Accounts()); await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(display: display)));
    await tester.pumpAndSettle();
    await tester.pump(campusGlassProbeDelay);
    await tester.pumpAndSettle();
    expect(display.glassMode, 'off');
    expect(find.text('玻璃效果在这台手机上显示异常，已关闭'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing, reason: '关闭档是实色，不再做模糊');
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('娱乐与积分：「我的」里一行写开着关着、点进设置页关掉后服务页不列游乐场、直接跳过去回服务页，打开就恢复；设置页底下删除数据先确认再清本机成绩', (tester) async {
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    final playground = PlaygroundStore.memory();
    await playground.finish('hanoi', PuzzleTier.entry, millis: 1000, at: DateTime.utc(2026, 11, 15));
    final leisure = Leisure(memory: FileLeisureMemory.memory(), clearLocal: playground.clear);
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(playground: playground, leisure: leisure))); await tester.pumpAndSettle();
    await tester.tap(find.text('服务').last); await tester.pumpAndSettle();
    expect(find.text('游乐场'), findsOneWidget);
    await tester.tap(find.text('我的')); await tester.pumpAndSettle();
    expect(find.text('已开启'), findsOneWidget);
    expect(find.byType(Switch), findsNothing, reason: '「我的」里这一行只写状态、点了进设置页，开关不与⋯挤在一行');
    await tester.tap(find.text('游乐场与积分')); await tester.pumpAndSettle();
    expect(find.byType(LeisurePage), findsOneWidget);
    await tester.tap(find.byType(CampusSwitchTile)); await tester.pumpAndSettle();
    expect(leisure.enabled, isFalse);
    await tester.tap(find.byTooltip('返回')); await tester.pumpAndSettle();
    expect(find.text('已关闭'), findsOneWidget);
    await tester.tap(find.text('服务').last); await tester.pumpAndSettle();
    expect(find.text('游乐场'), findsNothing);
    GoRouter.of(tester.element(find.byType(ServicePage))).go('/playground/hanoi');
    await tester.pumpAndSettle();
    expect(find.byType(HanoiPage), findsNothing);
    expect(find.byType(ServicePage), findsOneWidget);

    await tester.tap(find.text('我的')); await tester.pumpAndSettle();
    await tester.tap(find.text('游乐场与积分')); await tester.pumpAndSettle();
    await tester.tap(find.text('删除数据')); await tester.pumpAndSettle();
    expect(find.text('删除游乐场与积分的数据？'), findsOneWidget);
    expect(find.textContaining('服务器上的积分要登录应用账号后才能删'), findsOneWidget, reason: '没配中转、没登录应用账号时只清本机');
    expect(playground.best('hanoi', PuzzleTier.entry), isNotNull, reason: '确认之前不删');
    await tester.tap(find.text('删除')); await tester.pumpAndSettle();
    expect(playground.best('hanoi', PuzzleTier.entry), isNull);
    expect(find.text('已删除'), findsOneWidget);

    await tester.tap(find.byType(CampusSwitchTile)); await tester.pumpAndSettle();
    expect(leisure.enabled, isTrue);
    await tester.tap(find.byTooltip('返回')); await tester.pumpAndSettle();
    expect(find.text('已开启'), findsOneWidget);
    await tester.tap(find.text('服务').last); await tester.pumpAndSettle();
    expect(find.text('游乐场'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  // 解锁（规则见服务端 src/modules/unlock/unlock_rules.ts）：锁着的游戏与隐藏的工具连同快捷入口不让直接进，回到各自首页；开了照常进。
  testWidgets('锁着的游戏与隐藏的工具（含快捷入口）直接跳过去会回到各自首页，开了照常进', (tester) async {
    final fixture = ToolboxFixture();
    await tester.runAsync(fixture.initialize);
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway); await session.restore();
    final tool = fixture.runtime.modules.first;
    final unlocks = _Unlocks({'game.hanoi', toolboxUnlockId(tool.id)});
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(toolbox: fixture.runtime, playground: PlaygroundStore.memory(), unlocks: unlocks)));
    await tester.pumpAndSettle();
    GoRouter router() => GoRouter.of(tester.element(find.byType(Navigator).first));
    router().go('/playground/hanoi');
    await tester.pumpAndSettle();
    expect(find.byType(HanoiPage), findsNothing);
    expect(find.byType(PlaygroundPage), findsOneWidget);
    router().go('/toolbox/${tool.id}');
    await tester.pumpAndSettle();
    expect(find.byType(ToolboxPage), findsOneWidget);
    for (final shortcut in tool.shortcuts) {
      router().go('/toolbox/${tool.id}/${shortcut.id}');
      await tester.pumpAndSettle();
      expect(find.byType(ToolboxPage), findsOneWidget);
    }
    unlocks.closed.clear();
    router().go('/playground/hanoi');
    await tester.pumpAndSettle();
    expect(find.byType(HanoiPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.runAsync(fixture.close);
  });

  // 快捷入口直达（人工决策见 toolbox/express/express_page.dart 的 _openIdentity）。
  testWidgets('从快捷入口冷启动：会话恢复好后先到首页再推入入口页（属于百宝箱，没登录教务也能进），返回回到首页', (tester) async {
    final fixture = ToolboxFixture();
    await tester.runAsync(fixture.initialize);
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway);
    // 快递服务用内存会话存储（没登录拼多多），不会联网。
    final toolbox = ToolboxRuntime.testing(
      catalog: toolboxCatalog,
      store: fixture.store,
      downloads: fixture.manager,
      services: {ExpressService.serviceId: ExpressService(vault: MemoryExpressVault(), clientFactory: (session) => throw StateError('没登录不该建客户端'))},
    );
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, launch: 'express.identity', services: AppServices(toolbox: toolbox, shortcuts: _Shortcuts())));
    await tester.pump();
    expect(find.byType(ExpressPage), findsNothing, reason: '会话还没恢复好');
    await session.restore();
    await tester.pumpAndSettle();
    expect(find.byType(ExpressPage), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(ExpressPage), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.runAsync(fixture.close);
  });

  // 用户要求未登录也能进开发者模式：登录页有「关于」，进的是同一个关于页；开发者模式开着时每个页面边上浮着开发者工具按钮。
  testWidgets('登录页有关于入口；开发者模式开着时悬浮按钮浮在页面上，标记连同当前页面路径与说明写进日志', (tester) async {
    final temp = (await tester.runAsync(() => Directory.systemTemp.createTemp('lifecycle_logs')))!;
    final logs = (await tester.runAsync(() => DiagnosticLog.open(directory: Directory(path.join(temp.path, 'logs')), exports: Directory(path.join(temp.path, 'cache')), publish: (archive, filename) async => true)))!;
    final previous = campusLog;
    campusLog = logs.tee(previous);
    addTearDown(() {
      campusLog = previous;
      temp.deleteSync(recursive: true);
    });
    final developer = DeveloperSettings.memory();
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway); await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(developer: developer, logs: logs)));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byTooltip('开发者工具'), findsNothing);
    await tester.tap(find.text('关于')); await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    await tester.tap(find.byTooltip('返回')); await tester.pumpAndSettle();

    logs.developer = true;
    await developer.setEnabled(true); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开发者工具')); await tester.pumpAndSettle();
    expect(find.text('当前页面 /login'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '说明（可不填）'), '登录按钮 没反应');
    await tester.tap(find.text('标记这里'));
    for (var tick = 0; tick < 100 && find.text('已标记').evaluate().isEmpty; tick++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('已标记'), findsOneWidget);
    final records = (await tester.runAsync(() => logs.recent(errorsOnly: false)))!;
    expect(records.first.text, '[Mark] action=mark path=/login note=登录按钮 没反应');

    await developer.setEnabled(false); await tester.pumpAndSettle();
    expect(find.byTooltip('开发者工具'), findsNothing);
    await tester.pumpWidget(const SizedBox()); session.dispose();
  });

  // 审查发现：性能浮层用 MaterialApp 的开关时，开关一下整个页面外面多一层 Stack、换了父级要重建：入场淡入重放，悬浮按钮回到默认位置。
  testWidgets('开关性能浮层不重建页面：悬浮按钮留在拖到的位置，浮层画在最上面', (tester) async {
    final temp = (await tester.runAsync(() => Directory.systemTemp.createTemp('lifecycle_logs')))!;
    final logs = (await tester.runAsync(() => DiagnosticLog.open(directory: Directory(path.join(temp.path, 'logs')), exports: Directory(path.join(temp.path, 'cache')), publish: (archive, filename) async => true)))!;
    addTearDown(() => temp.deleteSync(recursive: true));
    final developer = DeveloperSettings.memory(enabled: true);
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway); await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(developer: developer, logs: logs)));
    await tester.pumpAndSettle();
    final button = find.byTooltip('开发者工具');
    await tester.drag(button, const Offset(0, -200));
    await tester.pumpAndSettle();
    final moved = tester.getRect(button);

    await developer.setPerformanceOverlay(true); await tester.pumpAndSettle();
    expect(find.byType(PerformanceOverlay), findsOneWidget);
    expect(tester.getRect(button), moved);
    await developer.setPerformanceOverlay(false); await tester.pumpAndSettle();
    expect(find.byType(PerformanceOverlay), findsNothing);
    expect(tester.getRect(button), moved);
    await tester.pumpWidget(const SizedBox()); session.dispose();
  });

  testWidgets('应用跟随系统与手动明暗切换保留页面上下文', (tester) async {
    final gateway = _Accounts();final session = AppSession(gateway);await session.restore();
    final display = DisplaySettings.memory();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(display: display)));await tester.pumpAndSettle();
    final today = tester.element(find.byType(TodayPage));
    expect(Theme.of(today).brightness, Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;await tester.pumpAndSettle();
    expect(Theme.of(today).brightness, Brightness.dark);
    final dateText = tester.widget<Text>(find.byWidgetPredicate((widget) => widget is Text && widget.data != null && RegExp(r'\d+月\d+日 周').hasMatch(widget.data!)).first);
    expect(dateText.style!.color, CampusPalette.of(today).onSurface);
    expect(identical(today, tester.element(find.byType(TodayPage))), isTrue);
    await display.setThemeMode(ThemeMode.light);await tester.pumpAndSettle();expect(Theme.of(today).brightness, Brightness.light);
    // 切到消息页再换深浅色：仍停在消息页，页面不重建。
    await tester.tap(find.text('消息').last);await tester.pumpAndSettle();
    final message = tester.element(find.byType(MessagePage));
    await display.setThemeMode(ThemeMode.dark);await tester.pumpAndSettle();
    expect(identical(message, tester.element(find.byType(MessagePage))), isTrue);
    expect(gateway.activeSession?.loginId, 'A');
    await tester.pumpWidget(const SizedBox());display.dispose();session.dispose();
  });
  testWidgets('悬浮底栏保留边距，末尾设置可滚到无遮挡位置', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740)); addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18)); await tester.pumpAndSettle();
    final bar = find.byType(DragNavigationBar); final rect = tester.getRect(bar);
    expect(rect.left, greaterThanOrEqualTo(16)); expect(rect.right, lessThanOrEqualTo(344)); expect(rect.bottom, lessThan(740));
    await tester.tap(find.text('我的').last); await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('关于')); await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('关于')).dy, lessThan(tester.getRect(bar).top));
    await tester.tap(find.text('关于')); await tester.pumpAndSettle();
    expect(find.text('Powered&Design By Galaxyous'), findsOneWidget);
    expect(tester.takeException(), isNull); await tester.pumpWidget(const SizedBox()); session.dispose();
  });
  testWidgets('启动自动检查查到新版时弹更新弹窗，只弹一次；关于页能检查更新', (tester) async {
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    final fixture = UpdateFixture()..feed.next = fakeRelease();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(updates: fixture.updates))); await tester.pumpAndSettle();
    await fixture.updates.autoCheck(); await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.text('稍后')); await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
    // 同一校园日再自动检查不联网、不再弹。
    await fixture.updates.autoCheck(); await tester.pumpAndSettle();
    expect(fixture.feed.calls, 1);
    expect(find.text('发现新版本'), findsNothing);
    await tester.tap(find.text('我的').last); await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('关于')); await tester.pumpAndSettle();
    await tester.tap(find.text('关于')); await tester.pumpAndSettle();
    expect(find.text('新版本 1.0.0-alpha.5'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); session.dispose();
  });
  testWidgets('首次启动先征得同意：开着时不弹更新、可点开全文；不同意先二次确认，再看看回到协议，退出应用不记同意；同意后记下并接着弹更新', (tester) async {
    var quits = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') quits++;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    final fixture = UpdateFixture()..feed.next = fakeRelease();
    final legal = LegalNoticeMemory.memory();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(updates: fixture.updates, legal: legal))); await tester.pumpAndSettle();
    legal.check(legalRevision); await tester.pumpAndSettle();
    expect(find.text('用户协议与隐私政策'), findsOneWidget);
    // 点遮罩关不掉。
    await tester.tapAt(const Offset(4, 4)); await tester.pumpAndSettle();
    expect(find.text('用户协议与隐私政策'), findsOneWidget);
    await fixture.updates.autoCheck(); await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
    // 全文页推在弹窗上：进出转场期间页面垫一份背景副本盖住弹窗（页面透明，不垫会和弹窗叠成两层），停稳后撤掉，背景只剩一份。
    int backdrops() => find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is AtmospherePainter).evaluate().length;
    expect(backdrops(), 1);
    await tester.tap(find.text('隐私政策')); await tester.pump(); await tester.pump(const Duration(milliseconds: 90));
    expect(backdrops(), 2);
    await tester.pumpAndSettle();
    expect(find.byType(LegalPage), findsOneWidget);
    expect(backdrops(), 1);
    await tester.tap(find.byTooltip('返回')); await tester.pump(); await tester.pump(const Duration(milliseconds: 90));
    expect(backdrops(), 2);
    await tester.pumpAndSettle();
    expect(find.byType(LegalPage), findsNothing);
    expect(backdrops(), 1);
    expect(find.text('用户协议与隐私政策'), findsOneWidget);
    await tester.tap(find.text('不同意')); await tester.pumpAndSettle();
    expect(find.text('需要你的同意'), findsOneWidget);
    await tester.tap(find.text('再看看')); await tester.pumpAndSettle();
    expect(find.text('需要你的同意'), findsNothing);
    expect(find.text('用户协议与隐私政策'), findsOneWidget);
    await tester.tap(find.text('不同意')); await tester.pumpAndSettle();
    await tester.tap(find.text('退出应用')); await tester.pumpAndSettle();
    expect(quits, 1);
    expect(legal.agreedRevision, isNull);
    expect(find.text('发现新版本'), findsNothing);
    // 下次打开再问；同意后两项都记下，接着弹被搁下的更新。
    legal.check(legalRevision); await tester.pumpAndSettle();
    expect(find.text('用户协议与隐私政策'), findsOneWidget);
    var agreed = false;
    unawaited(legal.agreed.then((_) => agreed = true));
    await tester.tap(find.text('同意')); await tester.pumpAndSettle();
    expect((legal.agreedRevision, legal.seenRevision), (legalRevision, legalRevision));
    expect(agreed, isTrue);
    expect(find.text('用户协议与隐私政策'), findsNothing);
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.text('稍后')); await tester.pumpAndSettle();
    legal.check(legalRevision); await tester.pumpAndSettle();
    expect(find.text('用户协议与隐私政策'), findsNothing);
    expect(quits, 1);
    await tester.pumpWidget(const SizedBox()); session.dispose();
  });
  testWidgets('同意过的，协议与政策有实质变化时提示一次，只有「知道了」才记下，不再征得同意', (tester) async {
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    final legal = LegalNoticeMemory.memory(agreedRevision: legalRevision - 1, seenRevision: legalRevision - 1);
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(legal: legal))); await tester.pumpAndSettle();
    legal.check(legalRevision); await tester.pumpAndSettle();
    expect(find.text('协议与政策已更新'), findsOneWidget);
    expect(find.textContaining(legalChanges), findsOneWidget);
    expect(find.text('不同意'), findsNothing);
    await tester.tap(find.text('知道了')); await tester.pumpAndSettle();
    expect((legal.agreedRevision, legal.seenRevision), (legalRevision - 1, legalRevision));
    legal.check(legalRevision); await tester.pumpAndSettle();
    expect(find.text('协议与政策已更新'), findsNothing);
    await tester.pumpWidget(const SizedBox()); session.dispose();
  });
  testWidgets('自动检查更新等用户同意协议之后才开始', (tester) async {
    final fixture = UpdateFixture();
    final agreed = Completer<void>();
    watchAppUpdates(fixture.updates, AppHooks(agreed: agreed.future));
    await tester.pump(appUpdateAutoCheckDelay * 2);
    expect(fixture.feed.calls, 0);
    agreed.complete();
    await tester.pump();
    await tester.pump(appUpdateAutoCheckDelay);
    expect(fixture.feed.calls, 1);
  });
  testWidgets('按启动顺序：恢复会话换了代次后再核对，同意弹窗弹在新的账号应用上，不被重建拆掉', (tester) async {
    final gateway = _Accounts(); final session = AppSession(gateway);
    final legal = LegalNoticeMemory.memory();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(legal: legal))); await tester.pump();
    // 同 main：恢复会话（换代次、下一帧整个账号应用重建）后紧接着核对。
    gateway._generation++;
    await session.restore();
    unawaited(checkLegalNotice(legal));
    await tester.pumpAndSettle();
    expect(find.text('用户协议与隐私政策'), findsOneWidget);
    await tester.tap(find.text('同意')); await tester.pumpAndSettle();
    expect(legal.agreedRevision, legalRevision);
    await tester.pumpWidget(const SizedBox()); session.dispose();
  });
  testWidgets('切换账号登录页有进入与返回中间帧，取消保留原账号', (tester) async {
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18)); await tester.pumpAndSettle();
    await tester.tap(find.text('我的').last); await tester.pumpAndSettle();
    await tester.tap(find.text('用户A')); await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('切换账号')); await tester.tap(find.text('切换账号')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expectSliding(tester, find.byType(LoginPage));
    await tester.pumpAndSettle(); await tester.tap(find.byTooltip('返回')); await tester.pump(); await tester.pump(const Duration(milliseconds: 90));
    expectSliding(tester, find.byType(LoginPage));
    await tester.pumpAndSettle(); expect(gateway.activeSession?.loginId, 'A'); expect(find.byType(LoginPage), findsNothing);
    await tester.pumpWidget(const SizedBox()); session.dispose();
  });
  testWidgets('入场淡入由上层背景副本淡出完成，内容和玻璃不套半透明图层', (tester) async {
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18)); await tester.pump(); await tester.pump(const Duration(milliseconds: 120));
    final veil = tester.widgetList<Opacity>(find.ancestor(of: find.byType(CustomPaint), matching: find.byType(Opacity))).map((widget) => widget.opacity);
    expect(veil.where((opacity) => opacity > 0 && opacity < 1), isNotEmpty);
    find.byType(ShellPage).evaluate().single.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Opacity) expect(widget.opacity, 1);
      if (widget is FadeTransition) expect(widget.opacity.value, 1);
      return true;
    });
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(CampusBackdrop), matching: find.byType(Opacity)).evaluate().where((element) => (element.widget as Opacity).opacity < 1), isEmpty);
    // 顶栏透明、与主体同一背景，整页只剩悬浮底栏一块玻璃面板。
    expect(find.byType(GlassPanel), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); session.dispose();
  });
  test('账号卡副标题：有姓名写学号 · 班级，姓名未知时标题已是学号只写班级', () {
    expect(accountDetail(const SessionView(loginId: '20260001', name: '用户A', className: '示例班')), '20260001 · 示例班');
    expect(accountDetail(const SessionView(loginId: '20260001', name: '', className: '示例班')), '示例班');
    expect(accountDetail(const SessionView(loginId: '20260001', name: '用户A', className: '')), '20260001');
    expect(accountDetail(null), '');
  });

  testWidgets('登录页同意勾选框读屏读整句、点文字也能勾选；登录后我的页头像卡只写姓名，学号点进账号页才写', (tester) async {
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway);
    await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18));
    await tester.pumpAndSettle();
    Checkbox agree() => tester.widget<Checkbox>(find.byKey(const ValueKey('agree-terms')));
    expect(agree().semanticLabel, '我已阅读并同意用户协议和隐私政策');
    // 整句只在勾选框上读一次，旁边的文字不再单独朗读。
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('我已阅读并同意'), findsNothing);
    expect(find.bySemanticsLabel('我已阅读并同意用户协议和隐私政策'), findsOneWidget);
    handle.dispose();
    await tester.tap(find.text('我已阅读并同意'));
    await tester.pump();
    expect(agree().value, isTrue);
    await tester.tap(find.text('我已阅读并同意'));
    await tester.pump();
    expect(agree().value, isFalse);
    await tester.tap(find.text('我已阅读并同意'));
    await tester.enterText(find.byType(TextField).at(0), 'A');
    await tester.enterText(find.byType(TextField).at(1), 'ok');
    await tester.pump();
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    expect(find.text('用户A'), findsOneWidget);
    expect(find.text('A'), findsNothing);
    await tester.tap(find.text('用户A'));
    await tester.pumpAndSettle();
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('登录按钮常亮：没填的项原地写明，没勾同意先提示并给同意行衬色、不发起登录；勾上后键盘「完成」直接登录', (tester) async {
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway);
    await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18));
    await tester.pumpAndSettle();
    expect(find.text('学号'), findsOneWidget);
    expect(find.byTooltip('显示密码'), findsOneWidget);
    final button = find.widgetWithText(FilledButton, '登录');
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pump();
    expect(find.text('请输入学号'), findsOneWidget);
    expect(find.text('请输入密码'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'A');
    await tester.enterText(find.byType(TextField).at(1), 'ok');
    await tester.pump();
    expect(find.text('请输入学号'), findsNothing);
    await tester.tap(button);
    await tester.pump();
    expect(find.text('请先阅读并同意用户协议和隐私政策'), findsOneWidget);
    BoxDecoration row() => tester.widget<AnimatedContainer>(find.ancestor(of: find.text('我已阅读并同意'), matching: find.byType(AnimatedContainer)).first).decoration! as BoxDecoration;
    expect(row().color!.a, greaterThan(0));
    expect(gateway.activeSession, isNull);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(row().color!.a, 0);
    await tester.tap(find.text('我已阅读并同意'));
    await tester.pump();
    await tester.showKeyboard(find.byType(TextField).at(1));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(gateway.activeSession?.loginId, 'A');
    expect(tester.takeException(), isNull);
  });

  testWidgets('在服务、消息、我的按返回键先回到今天，账号页只在有旧数据时显示导入一行', (tester) async {
    final gateway = _Accounts()..deferred = true;
    final session = AppSession(gateway);
    await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    expect(find.byType(TodayPage), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TodayPage), findsOneWidget);
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('用户A'));
    await tester.pumpAndSettle();
    expect(find.text('导入旧版本数据'), findsNothing);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    gateway.legacyAvailable = true;
    await tester.tap(find.text('用户A'));
    await tester.pumpAndSettle();
    expect(find.text('导入旧版本数据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记住账号必须先同意，取消不勾选；成功后可在我的立即清除，清除后可原地输密码重新开启', (tester) async {
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway);
    await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18));
    await tester.pumpAndSettle();
    await tester.tap(find.text('记住账号'));
    await tester.pumpAndSettle();
    expect(find.textContaining('账号鉴权数据加密存储在本地'), findsOneWidget);
    expect(find.textContaining('HTTP'), findsOneWidget);
    expect(gateway.rememberRequests, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isFalse);
    await tester.tap(find.text('记住账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并开启'));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
    expect(gateway.rememberRequests, isEmpty);
    await tester.enterText(find.byType(TextField).at(0), 'A');
    await tester.enterText(find.byType(TextField).at(1), 'ok');
    await tester.tap(find.byKey(const ValueKey('agree-terms')));
    await tester.pump();
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(gateway.rememberRequests, [true]);
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('用户A'));
    await tester.pumpAndSettle();
    expect(find.text('已开启'), findsOneWidget);
    await tester.tap(find.text('记住账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭并清除'));
    await tester.pumpAndSettle();
    expect(gateway.forgotten, 1);
    // 关闭后可原地重新开启：输密码核对，错了说原因、不开启；对了显示已开启，停在账号页、不换代次。
    expect(find.text('未开启'), findsOneWidget);
    final generation = gateway.generation;
    await tester.tap(find.text('记住账号'));
    await tester.pumpAndSettle();
    expect(find.text('开启记住账号'), findsOneWidget);
    expect(find.text('关闭并清除'), findsNothing);
    await tester.enterText(find.byType(TextField).last, 'wrong');
    await tester.pump();
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(find.text('密码不正确'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('未开启'), findsOneWidget);
    await tester.tap(find.text('记住账号'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'ok');
    await tester.pump();
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(find.text('已开启'), findsOneWidget);
    expect(gateway.verifyPasswords, ['wrong', 'ok']);
    expect(gateway.generation, generation);
    expect(find.text('账号'), findsOneWidget);
    expect(gateway.activeSession?.loginId, 'A');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('账号页退出登录：警示确认后回登录页，账号页随旧代次一起销毁', (tester) async {
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18)); await tester.pumpAndSettle();
    await tester.tap(find.text('我的').last); await tester.pumpAndSettle();
    await tester.tap(find.text('用户A')); await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录')); await tester.pumpAndSettle();
    await tester.tap(find.text('取消')); await tester.pumpAndSettle();
    expect(gateway.activeSession?.loginId, 'A');
    await tester.tap(find.text('退出登录')); await tester.pumpAndSettle();
    await tester.tap(find.text('退出')); await tester.pumpAndSettle();
    expect(gateway.activeSession, isNull);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('退出登录'), findsNothing);
    expect(tester.takeException(), isNull); await tester.pumpWidget(const SizedBox()); session.dispose();
  });

  testWidgets('冷启动转人工登录的提示在登录页弹出', (tester) async {
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway)..pendingNotice = '保存的鉴权数据不可用，请手动登录。';
    await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18));
    await tester.pumpAndSettle();
    expect(find.text('保存的鉴权数据不可用，请手动登录。'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('底栏页面有中间帧且保留分支状态，课表系统返回也有反向中间帧', (tester) async {
    final gateway = _Accounts();
    final session = AppSession(gateway);
    await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18));
    await tester.pumpAndSettle();
    await tester.tap(find.text('消息').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    // 进出两个分支整屏并排平移：消息从右侧进入，今天向左退出，两页相接不重叠。
    final width = tester.getSize(find.byType(AnimatedBranches)).width;
    final entering = tester.getTopLeft(find.byType(MessagePage)).dx, leaving = tester.getTopLeft(find.byType(TodayPage)).dx;
    expect(entering, inExclusiveRange(0, width));
    expect(leaving, closeTo(entering - width, .5));
    expectSliding(tester, find.byType(MessagePage));
    expectSliding(tester, find.byType(TodayPage));
    await tester.pumpAndSettle();
    // 切走再回来，消息页还是原来那一个（分支状态保留，不重建）。
    final message = tester.element(find.byType(MessagePage));
    await tester.tap(find.text('服务').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('消息').last);
    await tester.pumpAndSettle();
    expect(identical(message, tester.element(find.byType(MessagePage))), isTrue);
    await tester.tap(find.text('服务').last);
    await tester.pumpAndSettle();
    // 课表、成绩在「学业」里（11-16，见 page/academic_page.dart）。
    await tester.tap(find.text('学业'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();
    expect(find.byType(SchedulePage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expectSliding(tester, find.byType(SchedulePage));
    await tester.pumpAndSettle();
    expect(find.byType(SchedulePage), findsNothing);
    expect(find.text('课表'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('选择控件选中、未选、禁用的实际文字颜色均清晰', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Scaffold(body: Column(children: [
      CampusGlassChip(label: '未选', selected: false, onSelected: (_) {}),
      CampusGlassChip(label: '已选', selected: true, onSelected: (_) {}),
      const CampusGlassChip(label: '禁用', selected: false, onSelected: null),
      const CampusGlassChip(label: '禁用已选', selected: true, onSelected: null),
      CampusGlassChip(label: '学年', selected: false, onSelected: (_) {}),
      Checkbox(value: true, onChanged: (_) {}),
      Checkbox(value: false, onChanged: (_) {}),
    ]))));
    for (final label in ['未选', '已选', '禁用', '禁用已选', '学年']) {
      final rich = tester.widget<RichText>(find.descendant(of: find.text(label), matching: find.byType(RichText)));
      final color = rich.text.style!.color!;
      expect(color, isNot(Colors.white));
      final background = label.contains('禁用') || label == '已选' ? CampusPalette.values.first.surfaceSelected : CampusPalette.values.first.glassFallback;
      final contrast = (background.computeLuminance() + .05) / (color.computeLuminance() + .05);
      expect(contrast, greaterThanOrEqualTo(4.5), reason: label);
    }
    final theme = Theme.of(tester.element(find.byType(Checkbox).first)).checkboxTheme;
    // 复选框选中与开关同为控件激活色；白色对勾对它不低于 4.5:1。
    final accent = CampusPalette.values.first.accent;
    expect(theme.fillColor!.resolve({WidgetState.selected}), accent);
    expect((1.05) / (accent.computeLuminance() + .05), greaterThanOrEqualTo(4.5));
    expect(theme.fillColor!.resolve({}), CampusPalette.values.first.surface);
    expect(theme.checkColor!.resolve({WidgetState.selected}), Colors.white);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换失败/取消保留旧账号页面，成功后销毁旧路由并显示新账号', (tester) async {
    final gateway = _Accounts();
    final session = AppSession(gateway);
    await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    expect(find.text('用户A'), findsOneWidget);
    await tester.tap(find.text('用户A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换账号'));
    await tester.pumpAndSettle();
    expect(find.text('登录并切换'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'B');
    await tester.enterText(find.byType(TextField).at(1), 'wrong');
    await tester.tap(find.byKey(const ValueKey('agree-terms')));
    await tester.pump();
    await tester.tap(find.text('登录并切换'));
    await tester.pumpAndSettle();
    expect(find.text('密码错误'), findsOneWidget);
    expect(gateway.activeSession!.loginId, 'A');
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('用户A'), findsOneWidget);
    await tester.tap(find.text('切换账号'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'B');
    await tester.enterText(find.byType(TextField).at(1), 'ok');
    await tester.tap(find.byKey(const ValueKey('agree-terms')));
    await tester.pump();
    await tester.tap(find.text('登录并切换'));
    await tester.pumpAndSettle();
    expect(gateway.activeSession!.loginId, 'B');
    expect(find.text('登录并切换'), findsNothing);
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    expect(find.text('用户B'), findsOneWidget);
    expect(find.text('用户A'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('导入完成跨路由重建仍显示结果，不自动认领旧库', (tester) async {
    final gateway = _Accounts()..legacyAvailable = true;
    final session = AppSession(gateway);
    await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18));
    await tester.pumpAndSettle();
    expect(find.text('确认旧数据归属'), findsOneWidget);
    expect(gateway.imports, 0);
    await tester.tap(find.text('暂不导入'));
    await tester.pumpAndSettle();
    expect(gateway.imports, 0);
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('用户A'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('导入旧版本数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入旧版本数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认属于我并导入'));
    await tester.pumpAndSettle();
    expect(gateway.imports, 1);
    expect(find.textContaining('已导入 3 项'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
  testWidgets('开发者的话：有没读的信时「我的」页那一行与底栏「我的」各一个小圆点，点开读过就消；没有信时不显示这一行', (tester) async {
    final semantics = tester.ensureSemantics();
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    final feed = _NoteFeed();
    final notes = DeveloperNotes(feed: feed, memory: FileDeveloperNoteMemory.memory());
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(notes: notes))); await tester.pumpAndSettle();
    await tester.tap(find.text('我的')); await tester.pumpAndSettle();
    expect(find.text('开发者的话'), findsNothing);
    await tester.runAsync(notes.refresh); await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^我的，有新的')), findsOneWidget);
    expect(find.text('开发者的话'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('有新的')), findsNWidgets(2));
    await tester.tap(find.text('开发者的话')); await tester.pumpAndSettle();
    // 从新到旧；没读的标出来。
    expect(tester.getTopLeft(find.text('第二封')).dy, lessThan(tester.getTopLeft(find.text('第一封')).dy));
    expect(find.bySemanticsLabel(RegExp(r'^没读，第二封')), findsOneWidget);
    await tester.tap(find.text('第二封')); await tester.pumpAndSettle();
    expect(find.text('第二封的正文\n\n第二段'), findsOneWidget);
    await tester.tap(find.byTooltip('返回')); await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^没读，第二封')), findsNothing);
    await tester.tap(find.text('第一封')); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回')); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回')); await tester.pumpAndSettle();
    expect(find.text('开发者的话'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('有新的')), findsNothing);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox()); session.dispose();
  });
  testWidgets('节日当天：停在首页时播这次节日的动画，同时抽签，抽中的放完动画接着拆红包；播过就不再播', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    final today = formatCampusDate(campusInstant());
    final occasion = FestivalOccasion(id: 'test-day', name: '合成节日', from: today, to: today, campaign: 'test-day');
    final scene = FestivalScene(occasion: occasion, length: const Duration(seconds: 2), builder: (context, progress) => const Center(child: Text('合成场景')));
    festivalCatalog.add(scene);
    addTearDown(() => festivalCatalog.remove(scene));
    final festivals = Festivals(occasions: [occasion], memory: FileFestivalMemory.memory(), client: _Reward(), account: () => const AppAccountRef(accountId: 'AAAAAAAAAAAAAAAAAAAAAA', slot: 'fake-slot'));
    final moments = AppMoments(festivals: festivals, timetable: () async => const CampusTimetable([]));
    final legal = LegalNoticeMemory.memory(agreedRevision: legalRevision, seenRevision: legalRevision);
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(legal: legal, festivals: festivals, moments: moments))); await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('合成场景'), findsOneWidget);
    expect(festivals.due, isNull, reason: '开始播就记下，不再播');
    await tester.pump(const Duration(seconds: 2)); await tester.pump(const Duration(milliseconds: 500)); await tester.pump(const Duration(seconds: 1));
    expect(find.text('合成场景'), findsNothing);
    expect(find.bySemanticsLabel('拆开红包'), findsOneWidget);
    expect(festivals.unrevealed, isNull, reason: '揭晓了就记下');
    await tester.pumpWidget(const SizedBox()); session.dispose(); moments.dispose();
  });
  // 人工决策见 domain/festival.dart：抽奖要登录应用账号；没登录的只看动画，放完提示一句，点「去登录」进应用账号页。
  testWidgets('节日当天没登录应用账号：照样播动画但不抽签，放完提示可以去登录，点「去登录」进应用账号页', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    final today = formatCampusDate(campusInstant());
    final occasion = FestivalOccasion(id: 'test-day', name: '合成节日', from: today, to: today, campaign: 'test-day');
    final scene = FestivalScene(occasion: occasion, length: const Duration(seconds: 2), builder: (context, progress) => const Center(child: Text('合成场景')));
    festivalCatalog.add(scene);
    addTearDown(() => festivalCatalog.remove(scene));
    final reward = _Reward();
    final festivals = Festivals(occasions: [occasion], memory: FileFestivalMemory.memory(), client: reward, account: () => null);
    final moments = AppMoments(festivals: festivals, timetable: () async => const CampusTimetable([]));
    final legal = LegalNoticeMemory.memory(agreedRevision: legalRevision, seenRevision: legalRevision);
    final appAccounts = AppAccounts(client: _NoAppAccount());
    await appAccounts.load();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(legal: legal, festivals: festivals, moments: moments, appAccounts: appAccounts))); await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('合成场景'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2)); await tester.pump(const Duration(milliseconds: 500)); await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('合成场景'), findsNothing);
    expect(find.bySemanticsLabel('拆开红包'), findsNothing);
    expect(reward.draws, 0);
    expect(find.text('登录应用账号就能参加这次抽奖'), findsOneWidget);
    await tester.tap(find.text('去登录')); await tester.pumpAndSettle();
    expect(find.byType(AppAccountPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); session.dispose(); moments.dispose();
  });
  testWidgets('新信在不迫切的时候弹出：开屏走完、停在底栏根页且上面没有别的页面；从别的页面回到根页时立即看一眼；每次前台最多一次', (tester) async {
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    final notes = DeveloperNotes(feed: _NoteFeed(), memory: FileDeveloperNoteMemory.memory());
    await tester.runAsync(notes.refresh);
    final moments = AppMoments(notes: notes, timetable: () async => const CampusTimetable([]));
    final splashGone = ValueNotifier(false);
    final legal = LegalNoticeMemory.memory(agreedRevision: legalRevision, seenRevision: legalRevision);
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, splashGone: splashGone, services: AppServices(legal: legal, notes: notes, moments: moments))); await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2)); await tester.pumpAndSettle();
    expect(find.text('知道了'), findsNothing, reason: '开屏还没走完');
    await tester.tap(find.text('我的')); await tester.pumpAndSettle();
    await tester.tap(find.text('关于')); await tester.pumpAndSettle();
    splashGone.value = true;
    await tester.pump(const Duration(seconds: 2)); await tester.pumpAndSettle();
    expect(find.text('知道了'), findsNothing, reason: '根页上面推着关于页');
    await tester.tap(find.byTooltip('返回')); await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); await tester.pumpAndSettle();
    expect(find.text('第二封'), findsOneWidget);
    expect(find.text('第二封的正文\n\n第二段'), findsOneWidget);
    expect(find.text('查看全部'), findsOneWidget, reason: '还有一封没读');
    await tester.tap(find.text('知道了')); await tester.pumpAndSettle();
    expect(find.text('第二封'), findsNothing);
    expect(notes.letter, isNull);
    // 弹过的信回到前台也不再弹。
    moments.foreground();
    await tester.pump(const Duration(seconds: 1)); await tester.pumpAndSettle();
    expect(find.text('知道了'), findsNothing);
    await tester.pumpWidget(const SizedBox()); session.dispose(); moments.dispose();
  });
}

// 快捷入口的系统端口：测试只用冷启动带来的入口，发布与添加到桌面什么也不做。
// 只按编号判锁着没有的解锁（界面与路由只用到 locked）。
class _Unlocks implements UnlockAccess {
  _Unlocks(this.closed);
  final Set<String> closed;
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  bool locked(String id) => closed.contains(id);
  @override
  RolloutUnlock? offer(String id) => null;
  @override
  List<RolloutUnlock> get purchasable => const [];
  @override
  Future<void> refresh() async {}
  @override
  Future<void> buy(String id) async {}
}

class _Shortcuts implements AppShortcutPort {
  @override
  Future<void> publish(List<AppShortcut> shortcuts) async {}
  @override
  Future<bool> pin(AppShortcut shortcut) async => false;
  @override
  Future<String?> takeLaunch() async => null;
  @override
  Stream<String> get launches => const Stream.empty();
}

class _Accounts extends AccountAccess {
  static const _term = TermRef(xn: '2026', xq: '0');
  int _generation = 0;
  SessionView? _active = const SessionView(loginId: 'A', name: '用户A', className: '');
  bool legacyAvailable = false;
  bool deferred = false;
  int imports = 0;
  bool remembered = false;
  int forgotten = 0;
  final rememberRequests = <bool>[];
  final verifyPasswords = <String>[];
  @override
  Future<GatewayResult<LoginView>> rememberWithPassword(String password) async {
    verifyPasswords.add(password);
    if (password == 'wrong') return const GatewayResult(ok: false, source: 'edu', fetchedAt: '', error: GatewayError(code: 'PASSWORD_WRONG', message: '密码不正确'));
    remembered = true;
    return GatewayResult(ok: true, source: 'edu', fetchedAt: '', data: LoginView(session: _active));
  }
  @override
  Future<GatewayResult<LoginView>> loginRemembered(String account, String password, {required bool remember}) async {
    rememberRequests.add(remember);
    if (password != 'wrong') remembered = remember;
    return login(account, password);
  }
  @override
  Future<bool> isRemembered() async => remembered;
  @override
  Future<void> forgetCredential() async { forgotten++; remembered = false; }
  @override
  int get generation => _generation;
  @override
  SessionView? get activeSession => _active;
  @override
  AccountIdentity? get activeIdentity => _active == null ? null : AccountIdentity(source: 'https://school.example', loginId: _active!.loginId);
  @override
  Future<GatewayResult<SessionView>> restoreSession() async => GatewayResult(ok: _active != null, source: 'local', fetchedAt: 'stamp', data: _active);
  @override
  Future<GatewayResult<LoginView>> login(String account, String password) async {
    if (password == 'wrong') return const GatewayResult(ok: false, source: 'edu', fetchedAt: 'stamp', error: GatewayError(code: 'PASSWORD_WRONG', message: '密码错误'));
    _active = SessionView(loginId: account, name: '用户$account', className: '');
    _generation++;
    notifyListeners();
    return GatewayResult(ok: true, source: 'edu', fetchedAt: 'stamp', data: LoginView(session: _active));
  }
  @override
  Future<void> cancelLogin() async {}
  @override
  Future<void> logout() async { _active = null; _generation++; notifyListeners(); }
  @override
  Future<LegacyImportState> legacyImportState() async => LegacyImportState(available: legacyAvailable, deferred: deferred);
  @override
  Future<void> deferLegacyImport() async { deferred = true; }
  @override
  Future<GatewayResult<LegacyImportReport>> importLegacy() async {
    imports++; legacyAvailable = false; _generation++; notifyListeners();
    return const GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: LegacyImportReport(imported: 3, skipped: 2));
  }
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #listTerms) return Future.value(const GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: [_term]));
    if (invocation.memberName == #readSchedule) return Future.value(GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: ScheduleView(term: _term, student: _active!, courses: [], revisionId: 'rev-test')));
    if (invocation.memberName == #readBells) return Future.value(const GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: BellsView(empty: true, message: '', term: _term, periods: [])));
    return super.noSuchMethod(invocation);
  }
}

// 转场中途：页面已离开原位但仍部分在屏内，且之上没有半透明图层（玻璃在其下取不到背景，结束时会突变）。
void expectSliding(WidgetTester tester, Finder page) {
  final width = tester.getSize(find.byType(MaterialApp).first).width;
  final left = tester.getTopLeft(page).dx;
  expect(left.abs(), inExclusiveRange(0, width));
  page.evaluate().single.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Opacity) expect(widget.opacity, 1);
    if (widget is FadeTransition) expect(widget.opacity.value, 1);
    return true;
  });
}

// 合成的抽签：一律抽中一个合成口令（测试里登录着一个合成的应用账号）。
class _Reward implements FestivalRewardClient {
  var draws = 0;
  @override
  Future<FestivalDraw> draw(AppAccountRef account, String campaign, {required String occasion, required int activeDays, bool levels = true}) async {
    draws++;
    return FestivalWon(FestivalPrize(occasion: occasion, kind: FestivalPrizeKind.password, content: '合成口令', note: '', wonAt: DateTime.now().toUtc()));
  }
}

// 开发者的话的合成清单：两封，第二封刚发出（会弹）。
class _NoteFeed implements DeveloperNoteFeed {
  @override
  Future<List<DeveloperNote>> fetch() async {
    final now = DateTime.now().toUtc();
    return [
      DeveloperNote(id: 'b', title: '第二封', publishedAt: now, body: '第二封的正文\n\n第二段'),
      DeveloperNote(id: 'a', title: '第一封', publishedAt: now.subtract(const Duration(days: 30)), body: '第一封的正文'),
    ];
  }
}

// 没登录的应用账号（节日提示去登录用）：只答读本机记录的两项，其余交给 noSuchMethod。
class _NoAppAccount implements AppAccountClient {
  @override
  Future<AppAccountSession?> accountOf() async => null;
  @override
  Future<List<AppAccountRef>> dropLegacy() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
