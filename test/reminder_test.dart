import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/course_reminder.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/page/reminder_dialog.dart';
import 'package:superxd/theme/campus_theme.dart';

const _term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
const _bells = [
  BellPeriod(period: 1, dayPart: '', dayPartCode: '', start: '08:00', end: '08:45'),
  BellPeriod(period: 2, dayPart: '', dayPartCode: '', start: '08:55', end: '09:40'),
  BellPeriod(period: 3, dayPart: '', dayPartCode: '', start: '10:00', end: '10:45'),
  BellPeriod(period: 4, dayPart: '', dayPartCode: '', start: '10:55', end: '11:40'),
];

CourseRecord _course(String name, List<CourseMeeting> meetings) =>
    CourseRecord(courseCode: name, courseName: name, sectionId: name, credit: 2, teacherName: '', meetings: meetings);

CourseMeeting _meeting(int weekday, int start, int end, List<int> weeks, {String place = ''}) =>
    CourseMeeting(weekday: weekday, periodStart: start, periodEnd: end, place: place, weeks: weeks);

// 开学日 2026-09-07 为周一。
final _courses = [
  _course('高等数学', [_meeting(1, 1, 2, [1, 2, 3, 4], place: '知敬楼405室')]),
  _course('英语', [_meeting(3, 3, 4, [2, 4], place: '知敬楼613室'), _meeting(4, 1, 1, [4])]),
  _course('体育', [_meeting(5, 9, 10, [1])]),
];

class _Gateway implements CampusGateway {
  List<TermRef> terms = [_term];
  ReminderSetting setting = ReminderSetting.initial;
  String? termStart = '2026-09-07';
  List<BellPeriod> bells = _bells;
  int saves = 0;

  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => GatewayResult(ok: true, source: 'local', fetchedAt: '', data: terms);
  @override
  Future<GatewayResult<ReminderSetting>> readReminderSetting(TermRef term) async => GatewayResult(ok: true, source: 'local', fetchedAt: '', data: setting);
  @override
  Future<GatewayResult<ReminderSetting>> saveReminderSetting(TermRef term, ReminderSetting value) async {
    saves++;
    setting = value;
    return GatewayResult(ok: true, source: 'user', fetchedAt: '', data: value);
  }

  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async => GatewayResult(
    ok: true,
    source: 'local',
    fetchedAt: '',
    data: ScheduleView(term: _term, student: const SessionView(loginId: 'A', name: '', className: ''), courses: _courses, empty: false, message: '', termStartDate: termStart, revisionId: 'r1'),
  );
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async =>
      GatewayResult(ok: true, source: 'local', fetchedAt: '', data: BellsView(empty: bells.isEmpty, message: '', term: term, periods: bells));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Port implements CourseReminderPort {
  ReminderCapability current = const ReminderCapability(notifications: true, exact: true);
  final replaced = <(List<PlannedReminder>, bool)>[];
  var notificationRequests = 0, exactRequests = 0;
  bool grantOnRequest = true;

  @override
  Future<ReminderCapability> capability() async => current;
  @override
  Future<bool> requestNotifications() async {
    notificationRequests++;
    if (grantOnRequest) current = ReminderCapability(notifications: true, exact: current.exact);
    return current.notifications;
  }

  @override
  Future<void> requestExact() async => exactRequests++;
  @override
  Future<void> replace(List<PlannedReminder> reminders, {required bool exact}) async => replaced.add((reminders, exact));
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('课程实例按时段×周次定位日期，跨月与校园时区正确；缺节次计数，缺开学日或作息给原因', () {
    final occurrences = courseOccurrences(courses: _courses, termStartDate: '2026-09-07', bells: _bells, from: '2026-09-07', to: '2026-10-04');
    expect(occurrences.items.map((item) => '${item.date} ${item.course.courseName}'), [
      '2026-09-07 高等数学',
      '2026-09-14 高等数学',
      '2026-09-16 英语',
      '2026-09-21 高等数学',
      '2026-09-28 高等数学',
      '2026-09-30 英语',
      '2026-10-01 英语',
    ]);
    final first = occurrences.items.first;
    expect(first.start, DateTime.utc(2026, 9, 7, 0, 0));
    expect(first.end, DateTime.utc(2026, 9, 7, 1, 40));
    expect(occurrences.items[5].start, DateTime.utc(2026, 9, 30, 2, 0));
    // 体育第9–10节在作息里不存在：不猜时刻，计入 unresolved。
    expect(occurrences.unresolved, 1);
    expect(occurrences.gap, isNull);
    expect(occurrences.items.map((item) => item.key).toSet(), hasLength(occurrences.items.length));
    final window = courseOccurrences(courses: _courses, termStartDate: '2026-09-07', bells: _bells, from: '2026-09-01', to: '2026-09-13');
    expect(window.items.map((item) => item.date), ['2026-09-07']);
    expect(courseOccurrences(courses: _courses, termStartDate: null, bells: _bells, from: '2026-09-07', to: '2026-09-13').gap, OccurrenceGap.termStart);
    expect(courseOccurrences(courses: _courses, termStartDate: '2026-09-07', bells: const [], from: '2026-09-07', to: '2026-09-13').gap, OccurrenceGap.bells);
    final onlyMissing = courseOccurrences(courses: [_courses.last], termStartDate: '2026-09-07', bells: _bells, from: '2026-09-07', to: '2026-09-13');
    expect([onlyMissing.items, onlyMissing.gap], [isEmpty, OccurrenceGap.bells]);
  });

  test('提醒规划跳过已过的提醒时刻，文案含时间节次地点，最多128条', () {
    final occurrences = courseOccurrences(courses: _courses, termStartDate: '2026-09-07', bells: _bells, from: '2026-09-07', to: '2026-09-20').items;
    // 9月7日08:00上课，提前15分钟即 07:45（UTC 前一天23:45）；此刻已过，跳过。
    final planned = planReminders(occurrences, leadMinutes: 15, now: DateTime.utc(2026, 9, 6, 23, 50));
    expect(planned.first.occurrence.date, '2026-09-14');
    expect(planned.first.fireAt, DateTime.utc(2026, 9, 13, 23, 45));
    expect([planned.first.title, planned.first.body], ['高等数学', '08:00 · 第1–2节 · 知敬楼405室']);
    expect(planned[1].body, '10:00 · 第3–4节 · 知敬楼613室');
    final many = [
      for (var day = 0; day < 200; day++)
        CourseOccurrence(date: '2026-09-07', start: DateTime.utc(2026, 9, 7).add(Duration(hours: day)), end: DateTime.utc(2026, 9, 7, 1).add(Duration(hours: day)), course: _courses.first, meeting: _courses.first.meetings.first),
    ];
    expect(planReminders(many, leadMinutes: 5, now: DateTime.utc(2026, 9, 1)), hasLength(reminderLimit));
  });

  test('对账：无学期、未开启或无通知权限时撤销；开启后安排未来14天，结果相同不重复替换，权限决定是否准时', () async {
    final gateway = _Gateway(), port = _Port();
    // 校园时间 9月13日（周日）12:00。
    final reminders = CampusReminders(gateway: gateway, port: port, clock: () => DateTime.utc(2026, 9, 13, 4));
    var status = await reminders.reconcile();
    expect(status.setting.enabled, isFalse);
    expect(port.replaced.single.$1, isEmpty);
    await reminders.reconcile();
    expect(port.replaced, hasLength(1));
    gateway.setting = const ReminderSetting(enabled: true, leadMinutes: 10);
    status = await reminders.reconcile();
    expect(port.replaced.last.$1.map((reminder) => reminder.occurrence.date), ['2026-09-14', '2026-09-16', '2026-09-21']);
    expect(port.replaced.last.$1.first.fireAt, DateTime.utc(2026, 9, 13, 23, 50));
    expect(port.replaced.last.$2, isTrue);
    expect([status.scheduled, status.lastDate, status.gap], [3, '2026-09-21', null]);
    await reminders.reconcile();
    expect(port.replaced, hasLength(2));
    port.current = const ReminderCapability(notifications: true, exact: false);
    await reminders.reconcile();
    expect([port.replaced, port.replaced.last.$2], [hasLength(3), isFalse]);
    port.current = const ReminderCapability(notifications: false, exact: false);
    status = await reminders.reconcile();
    expect([port.replaced.last.$1, status.scheduled], [isEmpty, 0]);
    port.current = const ReminderCapability(notifications: true, exact: true);
    gateway.termStart = null;
    status = await reminders.reconcile();
    expect([port.replaced.last.$1, status.gap], [isEmpty, OccurrenceGap.termStart]);
    gateway.terms = [];
    status = await reminders.reconcile();
    expect([status.term, port.replaced.last.$1], [isNull, isEmpty]);
  });

  test('账号库v5升级到v6新增提醒设置表，已有学期数据不受影响', () async {
    final directory = await Directory.systemTemp.createTemp('reminder-db-');
    final path = '${directory.path}/account.db';
    final old = await openDatabase(path, version: 5, onCreate: (db, _) async {
      await db.execute('CREATE TABLE term (xn TEXT NOT NULL, xq TEXT NOT NULL, label TEXT NOT NULL, is_current INTEGER NOT NULL DEFAULT 0, start_date TEXT, PRIMARY KEY (xn, xq))');
      await db.insert('term', {'xn': '2026', 'xq': '0', 'label': '旧学期', 'start_date': '2026-09-07'});
    });
    await old.close();
    final database = await AppDatabase.open(databasePath: path);
    expect(await database.readReminderSetting(_term), isNull);
    await database.saveReminderSetting(_term, const ReminderSetting(enabled: true, leadMinutes: 5), now: '2026-09-13T04:00:00Z');
    expect((await database.readReminderSetting(_term))?.leadMinutes, 5);
    expect(await database.termStartDate('2026', '0'), '2026-09-07');
    await database.close();
    await directory.delete(recursive: true);
  });

  testWidgets('提醒设置：开启时申请通知并保存，状态如实显示条数、截止日与可能延迟，可去开启准时提醒；缺作息时说明原因', (tester) async {
    final gateway = _Gateway(), port = _Port()
      ..current = const ReminderCapability(notifications: false, exact: false);
    final reminders = CampusReminders(gateway: gateway, port: port, clock: () => DateTime.utc(2026, 9, 13, 4));
    await tester.pumpWidget(MaterialApp(
      theme: campusTheme(),
      home: Scaffold(body: Builder(builder: (context) => Center(child: TextButton(
        onPressed: () => showReminderSettings(context, gateway: gateway, reminders: reminders),
        child: const Text('打开'),
      )))),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('上课前提醒我'), findsOneWidget);
    expect(find.text('提前'), findsNothing);
    await tester.tap(find.text('上课前提醒我'));
    await tester.pumpAndSettle();
    expect([port.notificationRequests, gateway.saves, gateway.setting.enabled], [1, 1, isTrue]);
    expect(find.text('已安排3次，至9月21日，可能晚几分钟。'), findsOneWidget);
    await tester.tap(find.text('准时提醒'));
    await tester.pump();
    expect(port.exactRequests, 1);
    await tester.tap(find.text('30分钟'));
    await tester.pumpAndSettle();
    expect(gateway.setting.leadMinutes, 30);
    gateway.bells = const [];
    await tester.tap(find.text('5分钟'));
    await tester.pumpAndSettle();
    expect(find.text('缺少作息时间，同步作息后才能安排提醒。'), findsOneWidget);
    expect(port.replaced.last.$1, isEmpty);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('上课前提醒我'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
