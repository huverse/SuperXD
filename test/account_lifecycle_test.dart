import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/today_page.dart';
import 'package:superxd/main.dart';
import 'package:superxd/page/animated_branches.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/page/login_page.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/short_video/short_video_page.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'toolbox_test_support.dart';

void main() {
  testWidgets('百宝箱免教务登录，但课表门禁仍有效', (tester) async {
    final fixture = ToolboxFixture();
    await tester.runAsync(fixture.initialize);
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway); await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, toolbox: fixture.runtime, backgroundPhase: .18));
    await tester.pumpAndSettle();
    await tester.tap(find.text('百宝箱'));
    await tester.pumpAndSettle();
    expect(find.byType(ToolboxPage), findsOneWidget);
    await tester.tap(find.text('短视频去水印解析【聚合】'));
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
    for (final title in ['服务协议', '隐私政策']) {
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

  testWidgets('应用跟随系统与手动明暗切换保留页面上下文', (tester) async {
    final gateway = _Accounts();final session = AppSession(gateway);await session.restore();
    final display = DisplaySettings.memory();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(SuperXdApp(session: session, display: display, backgroundPhase: .18));await tester.pumpAndSettle();
    final today = tester.element(find.byType(TodayPage));
    expect(Theme.of(today).brightness, Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;await tester.pumpAndSettle();
    expect(Theme.of(today).brightness, Brightness.dark);
    final dateText = tester.widget<Text>(find.byWidgetPredicate((widget) => widget is Text && widget.data != null && RegExp(r'\d+月\d+日 周').hasMatch(widget.data!)).first);
    expect(dateText.style!.color, CampusPalette.of(today).onSurface);
    expect(identical(today, tester.element(find.byType(TodayPage))), isTrue);
    await display.setThemeMode(ThemeMode.light);await tester.pumpAndSettle();expect(Theme.of(today).brightness, Brightness.light);
    await tester.tap(find.text('消息').last);await tester.pumpAndSettle();await tester.tap(find.text('私信'));await tester.pumpAndSettle();
    await display.setThemeMode(ThemeMode.dark);await tester.pumpAndSettle();expect(find.text('还没有私信'), findsOneWidget);
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
    await tester.ensureVisible(find.text('开源与第三方声明')); await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('开源与第三方声明')).dy, lessThan(tester.getRect(bar).top));
    await tester.tap(find.text('开源与第三方声明')); await tester.pumpAndSettle();
    expect(find.text('Powered&Design By Galaxyous'), findsOneWidget);
    expect(tester.takeException(), isNull); await tester.pumpWidget(const SizedBox()); session.dispose();
  });
  testWidgets('切换账号登录页有进入与返回中间帧，取消保留原账号', (tester) async {
    final gateway = _Accounts(); final session = AppSession(gateway); await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18)); await tester.pumpAndSettle();
    await tester.tap(find.text('我的').last); await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('切换账号')); await tester.tap(find.text('切换账号')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final fade = tester.widgetList<FadeTransition>(find.ancestor(of: find.byType(LoginPage), matching: find.byType(FadeTransition)));
    expect(fade.any((transition) => transition.opacity.value > 0 && transition.opacity.value < 1), isTrue);
    await tester.pumpAndSettle(); await tester.tap(find.byTooltip('返回')); await tester.pump(); await tester.pump(const Duration(milliseconds: 90));
    final exiting = tester.widgetList<FadeTransition>(find.ancestor(of: find.byType(LoginPage), matching: find.byType(FadeTransition)));
    expect(exiting.any((transition) => transition.opacity.value > 0 && transition.opacity.value < 1), isTrue);
    await tester.pumpAndSettle(); expect(gateway.activeSession?.loginId, 'A'); expect(find.byType(LoginPage), findsNothing);
    await tester.pumpWidget(const SizedBox()); session.dispose();
  });
  testWidgets('记住账号必须先同意，取消不勾选；成功后可在我的立即清除', (tester) async {
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
    await tester.ensureVisible(find.text('关闭记住账号'));
    await tester.tap(find.text('关闭记住账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭并清除'));
    await tester.pumpAndSettle();
    expect(gateway.forgotten, 1);
    expect(find.text('关闭记住账号'), findsNothing);
    expect(gateway.activeSession?.loginId, 'A');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('冷启动自动登录失败在登录页弹出提示', (tester) async {
    final gateway = _Accounts().._active = null;
    final session = AppSession(gateway)..pendingNotice = '自动登录需要验证码，请手动登录完成验证。';
    await session.restore();
    await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18));
    await tester.pumpAndSettle();
    expect(find.text('自动登录需要验证码，请手动登录完成验证。'), findsOneWidget);
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
    final opacity = tester.widgetList<FadeTransition>(find.descendant(of: find.byType(AnimatedBranches), matching: find.byType(FadeTransition))).map((widget) => widget.opacity.value);
    expect(opacity.where((value) => value > 0 && value < 1), hasLength(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('私信'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('服务').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('消息').last);
    await tester.pumpAndSettle();
    expect(find.text('还没有私信'), findsOneWidget);
    await tester.tap(find.text('服务').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();
    expect(find.byType(SchedulePage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final transitions = tester.widgetList<FadeTransition>(find.ancestor(of: find.byType(SchedulePage), matching: find.byType(FadeTransition)));
    expect(transitions.any((widget) => widget.opacity.value > 0 && widget.opacity.value < 1), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(SchedulePage), findsNothing);
    expect(find.text('课表'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('选择控件选中、未选、禁用的实际文字颜色均清晰', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Scaffold(body: Column(children: [
      ChoiceChip(label: const Text('未选'), selected: false, onSelected: (_) {}),
      ChoiceChip(label: const Text('已选'), selected: true, onSelected: (_) {}),
      const ChoiceChip(label: Text('禁用'), selected: false),
      const ChoiceChip(label: Text('禁用已选'), selected: true),
      FilterChip(label: const Text('学年'), selected: false, onSelected: (_) {}),
      Checkbox(value: true, onChanged: (_) {}),
      Checkbox(value: false, onChanged: (_) {}),
    ]))));
    for (final label in ['未选', '已选', '禁用', '禁用已选', '学年']) {
      final rich = tester.widget<RichText>(find.descendant(of: find.text(label), matching: find.byType(RichText)));
      final color = rich.text.style!.color!;
      expect(color, isNot(Colors.white));
      final background = label.contains('禁用') ? CampusPalette.values.first.glassFallback : label == '已选' ? CampusPalette.values.first.surfaceSelected : CampusPalette.values.first.surface;
      final contrast = (background.computeLuminance() + .05) / (color.computeLuminance() + .05);
      expect(contrast, greaterThanOrEqualTo(4.5), reason: label);
    }
    final theme = Theme.of(tester.element(find.byType(Checkbox).first)).checkboxTheme;
    expect(theme.fillColor!.resolve({WidgetState.selected}), CampusPalette.values.first.primary);
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
    if (invocation.memberName == #readSchedule) return Future.value(GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: ScheduleView(term: _term, student: _active!, courses: [])));
    if (invocation.memberName == #readBells) return Future.value(const GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: BellsView(empty: true, message: '', term: _term, periods: [])));
    return super.noSuchMethod(invocation);
  }
}
