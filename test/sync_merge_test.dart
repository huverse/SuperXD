import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/sync_merge_page.dart';
import 'package:superxd/page/sync_selection_dialog.dart';
import 'package:superxd/page/today_page.dart';
import 'package:superxd/theme/campus_theme.dart';

import 'fixture_campus_gateway.dart';

const _term = TermRef(xn: '2026', xq: '0', label: '合成学期');
const _student = SessionView(loginId: 'test', name: '', className: '');
GatewayResult<T> _ok<T>(T data) => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: data);

CourseRecord _course(String code, String name, {String place = '合成楼101', int weekday = 1}) => CourseRecord(
  courseCode: code,
  courseName: name,
  sectionId: 'S',
  credit: 2,
  teacherName: '合成甲',
  meetings: [CourseMeeting(weekday: weekday, periodStart: 1, periodEnd: 2, place: place, weeks: [1, 2, 3])],
);

// 上次教务同步的样子。
final _base = [
  _course('A', '高等数学'),
  _course('B', '大学英语', weekday: 2),
  _course('C', '线性代数', weekday: 3),
  _course('D', '合成体育', weekday: 4),
  _course('E', '合成思政', weekday: 5),
];
// 本地：改了大学英语与线性代数的教室，删了合成体育。
final _mine = [
  _course('A', '高等数学'),
  _course('B', '大学英语', place: '我改的楼', weekday: 2),
  _course('C', '线性代数', place: '我改的楼', weekday: 3),
  _course('E', '合成思政', weekday: 5),
];
// 教务：改了高等数学与线性代数的教室，删了合成思政，加了合成选修；合成体育还在。
final _edu = [
  _course('A', '高等数学', place: '教务新楼'),
  _course('B', '大学英语', weekday: 2),
  _course('C', '线性代数', place: '教务新楼', weekday: 3),
  _course('D', '合成体育', weekday: 4),
  _course('F', '合成选修', weekday: 6),
];

Widget _app(Widget home) => MaterialApp(theme: campusTheme(), home: home);

// 列表按需建，视口放高些，屏幕外的行也建出来。
void _tall(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(600, 2400);
  addTearDown(tester.view.reset);
}

void main() {
  late BuildContext hostContext;
  Widget host() => _app(Builder(builder: (context) {
    hostContext = context;
    return const Scaffold(body: SizedBox());
  }));

  // 打开合并页，返回交回来的选择（退出时是保留本地）。
  Future<Future<ScheduleResolution>> open(WidgetTester tester, _Gateway gateway) async {
    await tester.pumpWidget(host());
    final result = resolveScheduleSync(hostContext, gateway: gateway, term: _term, plan: SyncPlan(conflict: true, action: 'needs_confirm', revisionId: 'mine', base: _base), edu: _edu);
    await tester.pumpAndSettle();
    return result;
  }

  // 点应用；要删课时先确认（教务删掉、你没动过的合成思政默认勾着），点删掉。
  Future<void> apply(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(FilledButton, label));
    await tester.pumpAndSettle();
    if (find.text('删掉').evaluate().isNotEmpty) {
      await tester.tap(find.text('删掉'));
      await tester.pumpAndSettle();
    }
  }

  bool ticked(WidgetTester tester, String text) {
    final row = find.ancestor(of: find.text(text), matching: find.byType(InkWell)).first;
    return tester.widget<Checkbox>(find.descendant(of: row, matching: find.byType(Checkbox)).first).value == true;
  }

  group('合并页', () {
    testWidgets('写明是谁改的，默认只勾只有教务改的；你改过的、两边都改了的、你删的都先保留你的', (tester) async {
      _tall(tester);
      await open(tester, _Gateway());
      expect(find.text('教务改了'), findsOneWidget);
      expect(find.text('你改过，教务没变'), findsOneWidget);
      expect(find.text('你和教务都改了'), findsOneWidget);
      expect(find.text('教务新加的'), findsOneWidget);
      expect(find.text('你删掉的'), findsOneWidget);
      expect(find.text('教务删掉了'), findsOneWidget);

      expect(ticked(tester, '高等数学'), isTrue);
      expect(ticked(tester, '大学英语'), isFalse);
      expect(ticked(tester, '线性代数'), isFalse);
      expect(ticked(tester, '合成选修'), isTrue);
      expect(ticked(tester, '合成体育'), isFalse);
      expect(ticked(tester, '合成思政'), isTrue);
      // 高等数学的教室 1 项、加合成选修、删合成思政。
      expect(find.widgetWithText(FilledButton, '应用 3 项改动'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('应用：勾了的用教务的，没勾的保留你的，存的说明写改了几门', (tester) async {
      _tall(tester);
      final result = await open(tester, _Gateway());
      await apply(tester, '应用 3 项改动');
      final resolution = await result as MergeEdu;
      final byName = {for (final course in resolution.merged) course.courseName: course};
      expect(byName['高等数学']!.meetings.single.place, '教务新楼', reason: '只有教务改的，用教务的');
      expect(byName['大学英语']!.meetings.single.place, '我改的楼', reason: '你改的保留');
      expect(byName['线性代数']!.meetings.single.place, '我改的楼', reason: '两边都改的默认保留你的');
      expect(byName.containsKey('合成选修'), isTrue);
      expect(byName.containsKey('合成体育'), isFalse, reason: '你删的不加回来');
      expect(byName.containsKey('合成思政'), isFalse);
      expect(resolution.summary, '合并教务课表：改 1 门、加 1 门、删 1 门');
    });

    testWidgets('每项都能单独改：两边都改的也能勾成用教务的', (tester) async {
      _tall(tester);
      final result = await open(tester, _Gateway());
      await tester.tap(find.text('线性代数'));
      await tester.pump();
      expect(find.widgetWithText(FilledButton, '应用 4 项改动'), findsOneWidget);
      await apply(tester, '应用 4 项改动');
      final resolution = await result as MergeEdu;
      expect(resolution.merged.firstWhere((course) => course.courseName == '线性代数').meetings.single.place, '教务新楼');
    });

    testWidgets('一项都不勾时按钮是保留我的课表，交回保留本地', (tester) async {
      _tall(tester);
      final result = await open(tester, _Gateway());
      for (final name in ['高等数学', '合成选修', '合成思政']) {
        await tester.tap(find.text(name));
        await tester.pump();
      }
      await tester.tap(find.widgetWithText(FilledButton, '保留我的课表'));
      await tester.pumpAndSettle();
      expect((await result as KeepLocal).remember, isTrue);
    });

    testWidgets('整份替换要确认，取消了留在页面', (tester) async {
      _tall(tester);
      final result = await open(tester, _Gateway());
      await tester.tap(find.text('整份替换'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '换成教务课表'));
      await tester.pumpAndSettle();
      expect(find.text('换成教务课表？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('合并教务课表'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '换成教务课表'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '换成教务的'));
      await tester.pumpAndSettle();
      expect(await result, isA<TakeEdu>());
    });

    testWidgets('退出合并页同保留本地', (tester) async {
      final result = await open(tester, _Gateway());
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect((await result as KeepLocal).remember, isTrue);
    });

    testWidgets('本机课表读不到时说明原因，不打开合并页', (tester) async {
      final gateway = _Gateway()..readFails = true;
      final result = await open(tester, gateway);
      expect(find.text('合并教务课表'), findsNothing);
      expect(find.text('读取失败'), findsOneWidget);
      await tester.tap(find.byType(TextButton).last);
      await tester.pumpAndSettle();
      expect((await result as KeepLocal).remember, isFalse, reason: '用户没选过，留到打扰时机再问');
    });

    testWidgets('比对之后本机课表又被改过：说明原因、不打开合并页，留到打扰时机再问', (tester) async {
      final result = await open(tester, _Gateway()..revision = 'changed');
      expect(find.text('合并教务课表'), findsNothing);
      expect(find.text('课表刚刚有改动，请重新同步'), findsOneWidget);
      await tester.tap(find.byType(TextButton).last);
      await tester.pumpAndSettle();
      expect((await result as KeepLocal).remember, isFalse);
    });

    testWidgets('两边只是教学班号这类看不见的地方不一样：不打开合并页，直接用教务的', (tester) async {
      final renumbered = [
        for (final course in _mine) CourseRecord(courseCode: course.courseCode, courseName: course.courseName, sectionId: 'S9', credit: course.credit, teacherName: course.teacherName, meetings: course.meetings),
      ];
      await tester.pumpWidget(host());
      final result = resolveScheduleSync(hostContext, gateway: _Gateway(), term: _term, plan: SyncPlan(conflict: true, action: 'needs_confirm', revisionId: 'mine', base: _base), edu: renumbered);
      await tester.pumpAndSettle();
      expect(find.text('合并教务课表'), findsNothing);
      expect(await result, isA<TakeEdu>());
    });

    testWidgets('要删课时先确认（写明删哪几门），取消就留在合并页', (tester) async {
      _tall(tester);
      final result = await open(tester, _Gateway());
      await tester.tap(find.widgetWithText(FilledButton, '应用 3 项改动'));
      await tester.pumpAndSettle();
      expect(find.text('删掉 1 门课？'), findsOneWidget);
      expect(find.textContaining('合成思政\n'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('合并教务课表'), findsOneWidget);
      await apply(tester, '应用 3 项改动');
      expect(await result, isA<MergeEdu>());
    });

    testWidgets('合并出来的课表不合规时原地说明，留在合并页换一种勾法', (tester) async {
      _tall(tester);
      await tester.pumpWidget(host());
      final result = resolveScheduleSync(hostContext, gateway: _Gateway(), term: _term, plan: SyncPlan(conflict: true, action: 'needs_confirm', revisionId: 'mine', base: _base), edu: [..._edu, _course('G', '长' * 201, weekday: 7)]);
      await tester.pumpAndSettle();
      var settled = false;
      unawaited(result.then((_) => settled = true));
      await tester.tap(find.widgetWithText(FilledButton, '应用 4 项改动'));
      await tester.pumpAndSettle();
      expect(find.textContaining('这样合并不行'), findsOneWidget);
      await tester.tap(find.byType(TextButton).last);
      await tester.pumpAndSettle();
      expect(find.text('合并教务课表'), findsOneWidget);
      expect(settled, isFalse);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(settled, isTrue);
    });

    testWidgets('合并页开着时整个账号应用被换掉（切换账号）：同步那轮不挂着，当退出', (tester) async {
      final result = await open(tester, _Gateway());
      expect(find.text('合并教务课表'), findsOneWidget);
      var settled = false;
      unawaited(result.then((_) => settled = true));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(settled, isTrue);
      expect((await result as KeepLocal).remember, isTrue);
    });

    testWidgets('窄屏大字号下不溢出', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: campusTheme(),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.7)), child: child!),
        home: SyncMergePage(term: _term, base: _base, mine: _mine, edu: _edu),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('手动同步', () {
    testWidgets('教务课表和本地不一样时进合并页，应用后存成合并结果并报告', (tester) async {
      _tall(tester);
      final gateway = _Gateway();
      await tester.pumpWidget(_app(Scaffold(body: TodayPage(gateway: gateway))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('作息'));
      await tester.tap(find.text('成绩'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '开始同步'));
      await tester.pumpAndSettle();
      expect(find.text('合并教务课表'), findsOneWidget);
      await apply(tester, '应用 3 项改动');
      expect(find.textContaining('已合并所选改动'), findsOneWidget);
      expect(gateway.merged!.firstWhere((course) => course.courseName == '大学英语').meetings.single.place, '我改的楼');
      expect(gateway.mergedEdu!.firstWhere((course) => course.courseName == '大学英语').meetings.single.place, '合成楼101', reason: '教务那份原样记成基准');
      expect(gateway.expectedRevision, 'mine');
      expect(tester.takeException(), isNull);
    });

    testWidgets('保留本地记下这份教务课表，自动同步不再为它打扰', (tester) async {
      _tall(tester);
      final gateway = _Gateway();
      await tester.pumpWidget(_app(Scaffold(body: TodayPage(gateway: gateway))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('作息'));
      await tester.tap(find.text('成绩'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '开始同步'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('保留本地自定义版本'), findsOneWidget);
      expect(gateway.dismissed, isTrue);
      expect(gateway.merged, isNull);
    });
  });

  group('打扰时机的弹窗', () {
    final held = HeldScheduleSync(term: _term, courses: _edu, fetchedAt: 'stamp');

    testWidgets('暂存的那份已经没了（手动同步过、换过账号）：不弹，也不落库', (tester) async {
      final gateway = _Gateway()..holds = [];
      await tester.pumpWidget(host());
      final done = showHeldScheduleSync(hostContext, autoSync: AutoSync(gateway: gateway), gateway: gateway, held: held);
      await tester.pumpAndSettle();
      await done;
      expect(find.text('教务课表有更新'), findsNothing);
      expect((gateway.committed, gateway.merged), (false, null));
    });

    testWidgets('点空白处是以后再说：什么都不记', (tester) async {
      final gateway = _Gateway();
      await tester.pumpWidget(host());
      final done = showHeldScheduleSync(hostContext, autoSync: AutoSync(gateway: gateway), gateway: gateway, held: held);
      await tester.pumpAndSettle();
      expect(find.text('教务课表有更新'), findsOneWidget);
      expect(find.textContaining('合成学期'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await done;
      expect(gateway.dismissed, isFalse);
    });

    testWidgets('保留本地：这份不再提醒', (tester) async {
      final gateway = _Gateway();
      await tester.pumpWidget(host());
      final done = showHeldScheduleSync(hostContext, autoSync: AutoSync(gateway: gateway), gateway: gateway, held: held);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留本地'));
      await tester.pumpAndSettle();
      await done;
      expect(gateway.dismissed, isTrue);
    });

    testWidgets('逐项选择：打开合并页，应用后落库并原地说明；退出合并页是以后再说', (tester) async {
      _tall(tester);
      final gateway = _Gateway();
      await tester.pumpWidget(host());
      var done = showHeldScheduleSync(hostContext, autoSync: AutoSync(gateway: gateway), gateway: gateway, held: held);
      await tester.pumpAndSettle();
      await tester.tap(find.text('逐项选择'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await done;
      expect(gateway.dismissed, isFalse);
      expect(gateway.merged, isNull);

      done = showHeldScheduleSync(hostContext, autoSync: AutoSync(gateway: gateway), gateway: gateway, held: held);
      await tester.pumpAndSettle();
      await tester.tap(find.text('逐项选择'));
      await tester.pumpAndSettle();
      await apply(tester, '应用 3 项改动');
      await done;
      expect(gateway.merged, isNotNull);
      expect(find.textContaining('已合并所选改动'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('期间本地已换回教务的版本：不再冲突，直接落这份', (tester) async {
      final gateway = _Gateway()..conflict = false;
      await tester.pumpWidget(host());
      final done = showHeldScheduleSync(hostContext, autoSync: AutoSync(gateway: gateway), gateway: gateway, held: held);
      await tester.pumpAndSettle();
      await tester.tap(find.text('逐项选择'));
      await tester.pumpAndSettle();
      await done;
      expect(find.text('合并教务课表'), findsNothing);
      expect(gateway.committed, isTrue);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('自动同步设置', () {
    Future<(_Gateway, _Scheduler, AutoSync)> openSettings(WidgetTester tester) async {
      _tall(tester);
      final gateway = _Gateway(), scheduler = _Scheduler();
      final autoSync = AutoSync(gateway: gateway, scheduler: scheduler, clock: () => DateTime.utc(2026, 11, 5));
      await tester.pumpWidget(host());
      chooseSyncSelection(hostContext, gateway, autoSync: autoSync);
      await tester.pumpAndSettle();
      expect(find.text('未开启'), findsOneWidget);
      await tester.tap(find.text('未开启'));
      await tester.pumpAndSettle();
      return (gateway, scheduler, autoSync);
    }

    testWidgets('「同步范围」里能打开；打开开关后排上后台任务、入口写明间隔与范围', (tester) async {
      final (gateway, scheduler, _) = await openSettings(tester);
      expect(find.text('间隔'), findsNothing, reason: '关着时不摊开');
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(gateway.autoSyncSetting.enabled, isTrue);
      expect(scheduler.calls.last, 'schedule ${const Duration(days: 1)} ${Duration.zero}');
      expect(find.text('间隔'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '完成'));
      await tester.pumpAndSettle();
      // 「·」挂在前一项末尾（DotSeparatedText）。
      expect(find.text('每天\u00A0· '), findsOneWidget);
      expect(find.text('当前学年'), findsOneWidget);
    });

    testWidgets('间隔、学年与内容点了就存；学年选具体的再全取消回到当前学年；内容至少留一项', (tester) async {
      final (gateway, scheduler, _) = await openSettings(tester);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      await tester.tap(find.text('每 6 小时'));
      await tester.pumpAndSettle();
      expect(gateway.autoSyncSetting.interval, const Duration(hours: 6));
      expect(scheduler.calls.last, startsWith('schedule ${const Duration(hours: 6)}'));
      for (final label in ['每天', '每 3 天', '每周']) {
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(find.text('2025–2026').last);
      await tester.pumpAndSettle();
      expect(gateway.autoSyncSetting.years, {'2025'});
      await tester.tap(find.text('2025–2026').last);
      await tester.pumpAndSettle();
      expect(gateway.autoSyncSetting.years, isNull);

      await tester.tap(find.text('2026–2027').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('当前学年'));
      await tester.pumpAndSettle();
      expect(gateway.autoSyncSetting.years, isNull);

      // 下面还垫着「同步范围」弹窗（同名的学年与内容），取最上面这一层。默认课表与成绩：取消成绩后只剩课表，课表不让再取消。
      await tester.tap(find.widgetWithText(CheckboxListTile, '成绩').last);
      await tester.pumpAndSettle();
      expect(gateway.autoSyncSetting.contents, {SyncContent.schedule});
      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, '课表').last).onChanged, isNull);
      await tester.tap(find.widgetWithText(CheckboxListTile, '作息').last);
      await tester.pumpAndSettle();
      expect(gateway.autoSyncSetting.contents, {SyncContent.schedule, SyncContent.bells});
      expect(tester.takeException(), isNull);
    });

    testWidgets('写明上次的结果：登录过期已暂停', (tester) async {
      _tall(tester);
      final gateway = _Gateway();
      gateway.autoSyncSetting = const AutoSyncSetting(enabled: true);
      gateway.autoSyncStatus = AutoSyncStatus(lastAttemptAt: DateTime.utc(2026, 11, 5), state: AutoSyncState.failed, message: '合成的失败原因');
      final autoSync = AutoSync(gateway: gateway);
      await autoSync.accountChanged(signedIn: true);
      await tester.pumpWidget(host());
      chooseSyncSelection(hostContext, gateway, autoSync: autoSync);
      await tester.pumpAndSettle();
      await tester.tap(find.text('每天\u00A0· '));
      await tester.pumpAndSettle();
      expect(find.text('合成的失败原因'), findsOneWidget);
    });

    testWidgets('成绩页的同步范围没有自动同步入口', (tester) async {
      await tester.pumpWidget(host());
      final gateway = _Gateway();
      chooseSyncSelection(hostContext, gateway, initialContents: {SyncContent.grades}, allowedContents: {SyncContent.grades});
      await tester.pumpAndSettle();
      expect(find.textContaining('自动同步'), findsNothing);
    });

    testWidgets('窄屏大字号下设置弹窗不溢出', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.reset);
      final gateway = _Gateway();
      gateway.autoSyncSetting = const AutoSyncSetting(enabled: true);
      final autoSync = AutoSync(gateway: gateway);
      await autoSync.accountChanged(signedIn: true);
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        theme: campusTheme(),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.7)), child: child!),
        home: Builder(builder: (inner) {
          context = inner;
          return const Scaffold(body: SizedBox());
        }),
      ));
      chooseSyncSelection(context, gateway, autoSync: autoSync);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}

class _Scheduler implements BackgroundSyncScheduler {
  final calls = <String>[];
  @override
  Future<void> schedule(Duration interval, {required Duration delay}) async => calls.add('schedule $interval $delay');
  @override
  Future<void> cancel() async => calls.add('cancel');
}

class _Gateway extends FixtureCampusGateway {
  _Gateway() : super(readText: (name) => File('assets/fixtures/$name').readAsString());
  bool readFails = false;
  bool conflict = true;
  bool dismissed = false;
  bool committed = false;
  List<CourseRecord>? merged, mergedEdu;
  String? expectedRevision;
  // 读本机课表时的当前版本（比对时是 mine）。
  String revision = 'mine';
  // 本机库里等着选的教务课表（打扰时机弹之前会重读）。
  List<HeldScheduleSync> holds = [HeldScheduleSync(term: _term, courses: _edu, fetchedAt: 'stamp')];

  @override
  Future<GatewayResult<List<HeldScheduleSync>>> readHeldScheduleSyncs() async => _ok(holds);

  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => _ok(const [_term, TermRef(xn: '2025', xq: '1', label: '上学年')]);
  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() => listTerms();
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async {
    if (readFails) return const GatewayResult(ok: false, source: 'local', fetchedAt: 'stamp', error: GatewayError(code: 'LOCAL_STORAGE_FAILED', message: '读取失败'));
    return _ok(ScheduleView(term: scope.term, student: _student, courses: _mine, revisionId: revision));
  }

  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) async => _ok(ScheduleView(term: term, student: _student, courses: _edu));
  @override
  Future<GatewayResult<SyncPlan>> planScheduleSync(TermRef term, List<CourseRecord> courses) async =>
      _ok(conflict ? SyncPlan(conflict: true, action: 'needs_confirm', revisionId: 'mine', base: _base) : const SyncPlan(conflict: false, action: 'insert', revisionId: 'edu'));
  @override
  Future<GatewayResult<RevisionView>> commitScheduleSync(TermRef term, List<CourseRecord> courses, {required bool confirm, String? expectedRevisionId}) async {
    committed = true;
    return _ok(const RevisionView(id: 'rev', source: 'edu', createdAt: 'stamp', summary: '同步'));
  }

  @override
  Future<GatewayResult<RevisionView>> commitScheduleMerge(TermRef term, List<CourseRecord> courses, List<CourseRecord> merged, String summary, {required String? expectedRevisionId}) async {
    this.merged = merged;
    mergedEdu = courses;
    expectedRevision = expectedRevisionId;
    return _ok(RevisionView(id: 'rev', source: 'user', createdAt: 'stamp', summary: summary));
  }

  @override
  Future<GatewayResult<bool>> holdScheduleSync(TermRef term, List<CourseRecord> courses, {required bool dismissed}) async {
    this.dismissed = dismissed;
    return _ok(!dismissed);
  }

  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async => _ok(BellsView(empty: true, message: '', term: term, periods: const []));
  @override
  Future<GatewayResult<TermRef?>> readBellsSource(TermRef term) async => _ok(null);
}
