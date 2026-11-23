import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/sync_record.dart';
import 'package:superxd/app_services.dart';
import 'package:superxd/app_shell.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/page/academic_page.dart';
import 'package:superxd/page/campus_sync_dialogs.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/page/sync_records_page.dart';
import 'package:superxd/page/today_page.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'fixture_campus_gateway.dart';
import 'page_fixture_support.dart';

// 学业页与同步记录（11-16，人工决策见 page/academic_page.dart 与 domain/sync_record.dart）。
class _Accounts extends FixtureAccounts {
  _Accounts(super.inner) : super(signedIn: true);
  final restored = <String>[];

  @override
  Future<GatewayResult<List<SyncRecord>>> readSyncRecords() => inner.readSyncRecords();
  @override
  Future<GatewayResult<SyncRecord>> recordSync(SyncRecord record) => inner.recordSync(record);
  @override
  Future<GatewayResult<RevisionView>> restoreScheduleRevision(TermRef term, String id, {required String? expectedRevisionId}) async {
    restored.add('${term.key}/$id');
    return const GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: RevisionView(id: 'r3', source: 'user', createdAt: 'stamp', summary: '恢复'));
  }
}

SyncRecord _record() => SyncRecord(at: DateTime.now().toUtc(), trigger: SyncTrigger.auto, changes: [
  ScheduleSyncChange(termKey: pageTerm.key, termLabel: pageTerm.label, added: const ['合成物理'], changed: const ['合成高数：教师'], counts: (1, 0, 1), before: 'r1'),
  GradeSyncChange(termKey: pageTerm.key, termLabel: pageTerm.label, added: const ['合成概率 90'], counts: (1, 0)),
]);

Future<(_Accounts, AppSession)> _app(WidgetTester tester, {AutoSync? autoSync}) async {
  final fixtures = pageFixtures();
  final inner = FixtureCampusGateway(readText: (name) async => fixtures[name]!);
  final accounts = _Accounts(inner);
  final session = AppSession(accounts);
  await session.restore();
  await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(autoSync: autoSync)));
  await tester.pumpAndSettle();
  return (accounts, session);
}

void main() {
  testWidgets('服务页只有「学业」一项（课表、成绩在里面）；学业页写当前学期与最近一次同步，课表、成绩从这里进', (tester) async {
    final (accounts, session) = await _app(tester);
    await accounts.inner.recordSync(_record());
    GoRouter.of(tester.element(find.byType(ShellPage))).go('/service');
    await tester.pumpAndSettle();
    expect(find.text('学业'), findsOneWidget);
    expect(find.text('课表'), findsNothing);
    expect(find.text('成绩'), findsNothing);
    await tester.tap(find.text('学业'));
    await tester.pumpAndSettle();
    expect(find.byType(AcademicPage), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text == pageTerm.label), findsOneWidget, reason: '学期名在「学年」后切开换行，不折出孤字');
    // 11-17 设计审查：「同步」是动作、不推入新页，行尾不画「›」（同 iOS、鸿蒙设置的动作行）。
    expect(tester.widget<ListTile>(find.ancestor(of: find.text('同步'), matching: find.byType(ListTile)).first).trailing, isNull);
    expect(find.textContaining('自动同步于'), findsOneWidget);
    expect(find.text('课表有变化 · 新出 1 门成绩'), findsOneWidget, reason: '同步记录一行写最近一次的概括');
    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();
    expect(find.byType(SchedulePage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  // 11-18 用户截图：没同步完的概括很长，放在行尾时把「同步记录」挤成一字一行、压到图标上。
  // 11-23 全应用切换走查：课表页「去同步」这类从推入的页面回到今天页（go），上面那页退场时底下的分支直接换好，不再同时左右平移。
  testWidgets('从推入的页面回到今天页：底栏壳被盖着时分支直接换，只有上面那页退场', (tester) async {
    final (_, session) = await _app(tester);
    final router = GoRouter.of(tester.element(find.byType(ShellPage)));
    router.go('/service');
    await tester.pumpAndSettle();
    unawaited(router.push('/academic'));
    await tester.pumpAndSettle();
    router.go('/today');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final today = tester.widget<FractionalTranslation>(find.ancestor(of: find.byType(TodayPage, skipOffstage: false), matching: find.byType(FractionalTranslation, skipOffstage: false)).first);
    expect(today.translation, Offset.zero, reason: '今天这一栏已经在原位');
    expect(find.byType(AcademicPage), findsOneWidget, reason: '学业页还在退场');
    await tester.pumpAndSettle();
    expect(find.byType(AcademicPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('没同步完的长概括写在「同步记录」下面、最多两行，标题照常一行', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1080 / 391;
    addTearDown(tester.view.reset);
    final (accounts, session) = await _app(tester);
    await accounts.inner.recordSync(SyncRecord(at: DateTime.now().toUtc(), trigger: SyncTrigger.manual, failures: const ['学期列表：教务返回的数据格式不对，请稍后再试或反馈']));
    GoRouter.of(tester.element(find.byType(ShellPage))).go('/service');
    await tester.pumpAndSettle();
    await tester.tap(find.text('学业'));
    await tester.pumpAndSettle();
    final title = find.text('同步记录');
    expect(tester.getSize(title).height, lessThan(30), reason: '标题一行，不被挤成竖排');
    final row = tester.widget<ListTile>(find.ancestor(of: title, matching: find.byType(ListTile)).first);
    expect(row.subtitle, isA<Text>());
    expect((row.subtitle! as Text).maxLines, 2);
    final tile = find.ancestor(of: title, matching: find.byType(ListTile)).first;
    final icon = find.descendant(of: tile, matching: find.byType(CampusIcon)).first;
    expect(tester.getTopLeft(title).dx, greaterThan(tester.getTopRight(icon).dx), reason: '标题在图标右边，不压到图标上');
    expect(tester.getBottomLeft(find.descendant(of: tile, matching: find.textContaining('学期列表')).first).dy, greaterThan(tester.getBottomLeft(title).dy), reason: '概括在标题下面');
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('同步记录：从新到旧列出；点开列出哪几门课，课表的变化先确认再撤回（恢复同步前那一版）', (tester) async {
    final (accounts, session) = await _app(tester);
    await accounts.inner.recordSync(SyncRecord(at: DateTime.now().toUtc().subtract(const Duration(days: 1)), trigger: SyncTrigger.manual));
    await accounts.inner.recordSync(_record());
    unawaited(GoRouter.of(tester.element(find.byType(ShellPage))).push('/academic/records'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncRecordsPage), findsOneWidget);
    expect(tester.getTopLeft(find.text('课表有变化 · 新出 1 门成绩')).dy, lessThan(tester.getTopLeft(find.text('没有变化')).dy), reason: '新的在上面');
    await tester.tap(find.text('课表有变化 · 新出 1 门成绩'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncRecordPage), findsOneWidget);
    expect(find.text('新增：合成物理'), findsOneWidget);
    expect(find.text('改动：合成高数：教师'), findsOneWidget);
    expect(find.text('新出：合成概率 90'), findsOneWidget);
    await tester.tap(find.text('撤回这次的变化'));
    await tester.pumpAndSettle();
    expect(find.text('撤回这次的课表变化？'), findsOneWidget);
    expect(accounts.restored, isEmpty, reason: '确认之前不动');
    await tester.tap(find.text('撤回'));
    await tester.pumpAndSettle();
    expect(accounts.restored, ['${pageTerm.key}/r1']);
    expect(find.text('已撤回'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('自动同步留下、等你来选的教务课表在学业页「待处理」里；点同步结果通知直接进同步记录', (tester) async {
    final fixtures = pageFixtures();
    final autoSync = AutoSync(gateway: FixtureCampusGateway(readText: (name) async => fixtures[name]!))
      ..held = [HeldScheduleSync(term: pageTerm, courses: const [], fetchedAt: '2026-11-16T00:00:00.000Z')];
    final (_, session) = await _app(tester, autoSync: autoSync);
    unawaited(GoRouter.of(tester.element(find.byType(ShellPage))).push('/academic'));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text == '课表 · ${pageTerm.label}'), findsOneWidget);
    expect(find.text('教务有改动，和你改过的不一样'), findsOneWidget);
    notificationRoute.value = '/academic/records';
    addTearDown(() => notificationRoute.value = null);
    await tester.pumpAndSettle();
    expect(find.byType(SyncRecordsPage), findsOneWidget);
    expect(notificationRoute.value, isNull, reason: '推入后清掉，不重复推');
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  // 11-19 用户选定：前台的自动同步记下结果后，学业页与今天页马上重读本机，不用等切页或下次打开。
  testWidgets('前台自动同步记下结果：学业页马上换成最新一条记录，今天页看得见时马上重读本机', (tester) async {
    final fixtures = pageFixtures();
    final autoSync = _PingAutoSync(FixtureCampusGateway(readText: (name) async => fixtures[name]!));
    final logs = <String>[];
    final previous = campusLog;
    campusLog = logs.add;
    addTearDown(() => campusLog = previous);
    final (accounts, session) = await _app(tester, autoSync: autoSync);
    bool reread() => logs.any((log) => log.contains('[TodayPage] action=read_local') && log.contains('state=start'));
    logs.clear();
    autoSync.ping();
    await tester.pumpAndSettle();
    expect(reread(), isTrue, reason: '今天页看得见：马上重读');
    unawaited(GoRouter.of(tester.element(find.byType(ShellPage))).push('/academic'));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有同步记录'), findsOneWidget);
    await accounts.inner.recordSync(_record());
    logs.clear();
    autoSync.ping();
    await tester.pumpAndSettle();
    expect(find.textContaining('自动同步于'), findsOneWidget);
    expect(find.text('课表有变化 · 新出 1 门成绩'), findsOneWidget);
    expect(reread(), isFalse, reason: '今天页被盖住时不重读，切回来时再读');
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('同步结果弹窗列出这一轮改了什么', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Builder(builder: (context) => TextButton(
      onPressed: () => showCampusSyncReport(context, CampusSyncReport(const [SyncItemResult('课表 · 2026-2027学年第一学期', SyncOutcome.completed, '已同步')], record: _record())),
      child: const Text('打开'),
    ))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    // 每行标题按「 · 」分项排（DotSeparatedText），按整句找。
    Finder line(String text) => find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text == text);
    expect(line('课表 · 2026-2027学年第一学期 · 新增 1 门、改动 1 门'), findsOneWidget);
    expect(find.text('新增：合成物理；改动：合成高数：教师'), findsOneWidget);
    expect(line('成绩 · 2026-2027学年第一学期 · 新出 1 门'), findsOneWidget);
  });
}

class _PingAutoSync extends AutoSync {
  _PingAutoSync(CampusGateway gateway) : super(gateway: gateway);
  void ping() => notifyListeners();
}
