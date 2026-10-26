import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/device/notification_reminders.dart';
import 'package:superxd/domain/campus_clock.dart';
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
  // 每次替换记下（提醒、是否准时、是否发成实时更新）。
  final replaced = <(List<PlannedReminder>, bool, bool)>[];
  var notificationRequests = 0, exactRequests = 0, liveRequests = 0;
  bool grantOnRequest = true;

  @override
  Future<ReminderCapability> capability() async => current;
  @override
  Future<bool> requestNotifications() async {
    notificationRequests++;
    if (grantOnRequest) current = ReminderCapability(notifications: true, exact: current.exact, live: current.live, liveAllowed: current.liveAllowed);
    return current.notifications;
  }

  @override
  Future<void> requestExact() async => exactRequests++;
  @override
  Future<void> requestLive() async => liveRequests++;
  @override
  Future<void> replace(List<PlannedReminder> reminders, {required bool exact, required bool live}) async => replaced.add((reminders, exact, live));
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
    // iOS 每个应用最多挂 64 条待发通知：按系统给的上限只排这么多。
    expect(planReminders(many, leadMinutes: 5, now: DateTime.utc(2026, 9, 1), limit: 64), hasLength(64));
  });

  test('对账：按系统的待发上限安排，状态行的条数与截止日对得上', () async {
    final gateway = _Gateway(), port = _Port()..current = const ReminderCapability(notifications: true, exact: true, limit: 2);
    final reminders = CampusReminders(gateway: gateway, port: port, clock: () => DateTime.utc(2026, 9, 13, 4));
    gateway.setting = const ReminderSetting(enabled: true, leadMinutes: 10, live: false);
    final status = await reminders.reconcile();
    expect(port.replaced.last.$1.map((reminder) => reminder.occurrence.date), ['2026-09-14', '2026-09-16']);
    expect([status.scheduled, status.lastDate], [2, '2026-09-16']);
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
    gateway.setting = const ReminderSetting(enabled: true, leadMinutes: 10, live: false);
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

  test('账号库v5升级到v7新增提醒设置表，已有学期数据不受影响', () async {
    final directory = await Directory.systemTemp.createTemp('reminder-db-');
    final path = '${directory.path}/account.db';
    final old = await openDatabase(path, version: 5, onCreate: (db, _) async {
      await db.execute('CREATE TABLE term (xn TEXT NOT NULL, xq TEXT NOT NULL, label TEXT NOT NULL, is_current INTEGER NOT NULL DEFAULT 0, start_date TEXT, PRIMARY KEY (xn, xq))');
      await db.insert('term', {'xn': '2026', 'xq': '0', 'label': '旧学期', 'start_date': '2026-09-07'});
    });
    await old.close();
    final database = await AppDatabase.open(databasePath: path);
    expect(await database.readReminderSetting(_term), isNull);
    await database.saveReminderSetting(_term, const ReminderSetting(enabled: true, leadMinutes: 5, live: false), now: '2026-09-13T04:00:00Z');
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

  test('对账：开了状态栏胶囊且系统有实时更新才发成实时更新；开关、系统支持变化都重新替换，关提醒时一并撤销', () async {
    final gateway = _Gateway()..setting = const ReminderSetting(enabled: true, leadMinutes: 10, live: true);
    final port = _Port();
    final reminders = CampusReminders(gateway: gateway, port: port, clock: () => DateTime.utc(2026, 9, 13, 4));
    // Android 15 及以下没有实时更新：设置开着也照常是普通提醒。
    await reminders.reconcile();
    expect([port.replaced.last.$1, port.replaced.last.$3], [hasLength(3), isFalse]);
    port.current = const ReminderCapability(notifications: true, exact: true, live: true);
    final status = await reminders.reconcile();
    expect([port.replaced, port.replaced.last.$1, port.replaced.last.$3], [hasLength(2), hasLength(3), isTrue]);
    expect([status.setting.live, status.capability.liveAllowed], [isTrue, isFalse]);
    await reminders.reconcile();
    expect(port.replaced, hasLength(2));
    gateway.setting = const ReminderSetting(enabled: true, leadMinutes: 10, live: false);
    await reminders.reconcile();
    expect([port.replaced, port.replaced.last.$3], [hasLength(3), isFalse]);
    gateway.setting = const ReminderSetting(enabled: false, leadMinutes: 10, live: true);
    await reminders.reconcile();
    expect([port.replaced.last.$1, port.replaced.last.$3], [isEmpty, isFalse]);
    // 9月14日 08:30 正在上高等数学（08:00–09:40）：胶囊这节留到下课，回前台重新对账不会撤掉；普通提醒时刻已过不再安排。
    gateway.setting = const ReminderSetting(enabled: true, leadMinutes: 10, live: true);
    final during = CampusReminders(gateway: gateway, port: port, clock: () => DateTime.utc(2026, 9, 14, 0, 30));
    await during.reconcile();
    expect(port.replaced.last.$1.map((reminder) => reminder.occurrence.date), ['2026-09-14', '2026-09-16', '2026-09-21']);
    gateway.setting = const ReminderSetting(enabled: true, leadMinutes: 10, live: false);
    await during.reconcile();
    expect(port.replaced.last.$1.map((reminder) => reminder.occurrence.date), ['2026-09-16', '2026-09-21']);
  });

  test('账号库v6升级到v7给提醒设置加状态栏胶囊列：已有设置保留、胶囊默认关闭，可保存开启', () async {
    final directory = await Directory.systemTemp.createTemp('reminder-db-');
    final path = '${directory.path}/account.db';
    final old = await openDatabase(path, version: 6, onCreate: (db, _) async {
      await db.execute('CREATE TABLE term (xn TEXT NOT NULL, xq TEXT NOT NULL, label TEXT NOT NULL, is_current INTEGER NOT NULL DEFAULT 0, start_date TEXT, PRIMARY KEY (xn, xq))');
      await db.execute('CREATE TABLE reminder_setting (xn TEXT NOT NULL, xq TEXT NOT NULL, enabled INTEGER NOT NULL, lead_minutes INTEGER NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (xn, xq))');
      await db.insert('reminder_setting', {'xn': '2026', 'xq': '0', 'enabled': 1, 'lead_minutes': 5, 'updated_at': '2026-09-13T04:00:00Z'});
    });
    await old.close();
    final database = await AppDatabase.open(databasePath: path);
    final kept = await database.readReminderSetting(_term);
    expect([kept?.enabled, kept?.leadMinutes, kept?.live], [isTrue, 5, isFalse]);
    await database.saveReminderSetting(_term, const ReminderSetting(enabled: true, leadMinutes: 5, live: true), now: '2026-09-13T05:00:00Z');
    expect((await database.readReminderSetting(_term))?.live, isTrue);
    await database.close();
    await directory.delete(recursive: true);
  });

  testWidgets('提醒设置：系统有实时更新才给状态栏胶囊开关，改提前时间与开关提醒不丢胶囊设置；系统未允许时如实说明并可去开启', (tester) async {
    final gateway = _Gateway()..setting = const ReminderSetting(enabled: true, leadMinutes: 15, live: false);
    final port = _Port();
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
    expect(find.text('提前'), findsOneWidget);
    expect(find.text('状态栏胶囊'), findsNothing);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    port.current = const ReminderCapability(notifications: true, exact: true, live: true);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('系统未允许状态栏胶囊，只显示为普通通知。'), findsNothing);
    await tester.tap(find.text('状态栏胶囊'));
    await tester.pumpAndSettle();
    expect([gateway.setting.live, gateway.setting.enabled, gateway.setting.leadMinutes, port.replaced.last.$3], [isTrue, isTrue, 15, isTrue]);
    await tester.ensureVisible(find.text('开启胶囊'));
    expect(find.text('系统未允许状态栏胶囊，只显示为普通通知。'), findsOneWidget);
    await tester.tap(find.text('开启胶囊'));
    await tester.pump();
    expect(port.liveRequests, 1);
    await tester.ensureVisible(find.text('30分钟'));
    await tester.tap(find.text('30分钟'));
    await tester.pumpAndSettle();
    expect([gateway.setting.leadMinutes, gateway.setting.live], [30, isTrue]);
    await tester.ensureVisible(find.text('上课前提醒我'));
    await tester.tap(find.text('上课前提醒我'));
    await tester.pumpAndSettle();
    expect([gateway.setting.enabled, gateway.setting.live, port.replaced.last.$1], [isFalse, isTrue, isEmpty]);
    expect(find.text('状态栏胶囊'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('适配器：开了胶囊把提醒交给原生侧发实时更新（钟点按校园时区写好）、撤掉插件里的提醒；关了交空计划、照常由插件定时', () async {
    ensureCampusClock();
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    final plugin = <MethodCall>[], live = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pluginChannel = MethodChannel('dexterous.com/flutter/local_notifications'), liveChannel = MethodChannel('superxd/course_live');
    messenger.setMockMethodCallHandler(pluginChannel, (call) async {
      plugin.add(call);
      return switch (call.method) {
        'initialize' => true,
        'pendingNotificationRequests' => [
          {'id': 610003, 'title': '旧提醒', 'body': '', 'payload': null},
          {'id': 7, 'title': '下载进度', 'body': '', 'payload': null},
        ],
        'areNotificationsEnabled' => true,
        'canScheduleExactNotifications' => false,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(liveChannel, (call) async {
      live.add(call);
      return call.method == 'capability' ? {'live': true, 'allowed': false} : null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(pluginChannel, null);
      messenger.setMockMethodCallHandler(liveChannel, null);
    });
    final capability = await NotificationReminders().capability();
    expect([capability.notifications, capability.exact, capability.live, capability.liveAllowed], [isTrue, isFalse, isTrue, isFalse]);
    final course = _courses.first;
    final occurrence = CourseOccurrence(date: '2099-09-07', start: DateTime.utc(2099, 9, 7), end: DateTime.utc(2099, 9, 7, 1, 40), course: course, meeting: course.meetings.first);
    final planned = planReminders([occurrence], leadMinutes: 10, now: DateTime.utc(2026, 9, 13));
    await NotificationReminders().replace(planned, exact: true, live: true);
    // 只撤自己 id 段里的旧提醒，不碰下载进度；实时更新那条路不经插件定时。
    expect(plugin.where((call) => call.method == 'cancel'), hasLength(1));
    expect(plugin.where((call) => call.method == 'zonedSchedule'), isEmpty);
    expect(jsonDecode(live.last.arguments['items'] as String), [
      {
        'key': occurrence.key,
        'fireAt': DateTime.utc(2099, 9, 6, 23, 50).millisecondsSinceEpoch,
        'start': DateTime.utc(2099, 9, 7).millisecondsSinceEpoch,
        'end': DateTime.utc(2099, 9, 7, 1, 40).millisecondsSinceEpoch,
        'title': '高等数学',
        'before': '08:00 · 第1–2节 · 知敬楼405室',
        'during': '上课中 · 至09:40 · 知敬楼405室',
      },
    ]);
    plugin.clear();
    await NotificationReminders().replace(planned, exact: true, live: false);
    expect(jsonDecode(live.last.arguments['items'] as String), isEmpty);
    expect(plugin.where((call) => call.method == 'zonedSchedule'), hasLength(1));
    await NotificationReminders().requestLive();
    expect(live.last.method, 'openSettings');
  });
}
