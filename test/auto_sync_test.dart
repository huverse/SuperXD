import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/application/app_moments.dart';
import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/gateway_code.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/app_database.dart';

import 'fixture_campus_gateway.dart';

const _term = TermRef(xn: '2026', xq: '0', label: '合成学期');
const _student = SessionView(loginId: 'test', name: '', className: '');

GatewayResult<T> _ok<T>(T data) => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: data);
GatewayResult<T> _fail<T>(String code) => GatewayResult(ok: false, source: 'edu', fetchedAt: 'stamp', error: GatewayError(code: code, message: code));

List<CourseRecord> _courses(String place) => [
  CourseRecord(courseCode: 'C', courseName: '合成课程', sectionId: 'S', credit: 1, teacherName: '合成甲', meetings: [CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: place, weeks: [1, 2, 3])]),
];

void main() {
  final now = DateTime.utc(2026, 11, 5, 8);

  group('到期规则', () {
    AutoSyncView view({bool enabled = true, Duration interval = const Duration(days: 1), DateTime? last, AutoSyncState? state}) =>
        AutoSyncView(setting: AutoSyncSetting(enabled: enabled, interval: interval), status: AutoSyncStatus(lastAttemptAt: last, state: state));

    test('关着不到期，从没跑过就到期', () {
      expect(autoSyncDue(view(enabled: false), now), isFalse);
      expect(autoSyncDue(view(), now), isTrue);
    });

    test('离上次过了间隔才到期；系统叫醒早一点（15 分钟内）也算到期，不白等一个周期', () {
      expect(autoSyncDue(view(last: now.subtract(const Duration(hours: 23))), now), isFalse);
      expect(autoSyncDue(view(last: now.subtract(const Duration(hours: 23, minutes: 50))), now), isTrue);
      expect(autoSyncDue(view(last: now.subtract(const Duration(days: 1))), now), isTrue);
    });

    test('登录过期暂停时后台不到期，用户打开着应用才照间隔试；没连上网的隔 15 分钟就能再试', () {
      expect(autoSyncDue(view(last: now.subtract(const Duration(days: 30)), state: AutoSyncState.paused), now), isFalse);
      expect(autoSyncDue(view(last: now.subtract(const Duration(days: 30)), state: AutoSyncState.paused), now, foreground: true), isTrue);
      expect(autoSyncDue(view(last: now.subtract(const Duration(hours: 1)), state: AutoSyncState.paused), now, foreground: true), isFalse);
      expect(autoSyncDue(view(last: now.subtract(const Duration(minutes: 10)), state: AutoSyncState.network), now), isFalse);
      expect(autoSyncDue(view(last: now.subtract(const Duration(minutes: 15)), state: AutoSyncState.network), now), isTrue);
    });

    test('后台任务第一次排在下次到期的时候，已过期的马上排', () {
      expect(autoSyncDelay(view(), now), Duration.zero);
      expect(autoSyncDelay(view(last: now.subtract(const Duration(hours: 6))), now), const Duration(hours: 18));
      expect(autoSyncDelay(view(last: now.subtract(const Duration(days: 3))), now), Duration.zero);
    });
  });

  group('账号库', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });
    late Directory directory;
    late AppDatabase database;
    late KingoCampusGateway gateway;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('auto-sync-');
      database = await AppDatabase.open(databasePath: '${directory.path}/account.db');
      gateway = KingoCampusGateway(database: database, now: () => now);
    });
    tearDown(() async {
      await database.close();
      await directory.delete(recursive: true);
    });

    Future<String> eduThenUser() async {
      await database.syncSchedule(_term, _courses('教务楼'), confirm: false, now: 'a');
      final head = await database.headRevisionId(_term);
      return (await database.saveSchedule(_term, _courses('我改的楼'), '改教室', expectedRevisionId: head, now: 'b')).id;
    }

    test('冲突时带上基准：最近一次教务同步的版本，不是当前的本地版本', () async {
      final head = await eduThenUser();
      final plan = (await gateway.planScheduleSync(_term, _courses('教务新楼'))).data!;
      expect(plan.conflict, isTrue);
      expect(plan.revisionId, head);
      expect(plan.base!.single.meetings.single.place, '教务楼');
      // 不冲突时不多读。
      await database.syncSchedule(_term, _courses('教务新楼'), confirm: true, expectedRevisionId: head, now: 'c');
      expect((await gateway.planScheduleSync(_term, _courses('教务再新楼'))).data!.base, isNull);
    });

    test('逐项合并一次落两版：教务同步成为下次的基准，合并结果是当前版本；两版都能恢复', () async {
      final head = await eduThenUser();
      final saved = await gateway.commitScheduleMerge(_term, _courses('教务新楼'), _courses('合并后的楼'), '合并教务课表：改 1 门', expectedRevisionId: head);
      expect(saved.ok, isTrue);
      expect(saved.data!.source, 'user');
      expect(saved.data!.summary, '合并教务课表：改 1 门');
      expect((await database.latestEduCourses(_term))!.single.meetings.single.place, '教务新楼');
      final rows = (await gateway.listScheduleRevisions(_term)).data!;
      expect(rows.map((row) => row.source), ['user', 'edu', 'user', 'edu']);
      expect(rows.first.current, isTrue);
    });

    test('合并结果和教务一样时只记一版教务同步', () async {
      final head = await eduThenUser();
      final saved = await gateway.commitScheduleMerge(_term, _courses('教务新楼'), _courses('教务新楼'), '合并', expectedRevisionId: head);
      expect(saved.data!.source, 'edu');
      expect((await gateway.listScheduleRevisions(_term)).data!.length, 3);
    });

    test('合并时课表已被改过：报冲突、一版都不写', () async {
      final head = await eduThenUser();
      await database.saveSchedule(_term, _courses('又改了'), '再改', expectedRevisionId: head, now: 'c');
      final saved = await gateway.commitScheduleMerge(_term, _courses('教务新楼'), _courses('合并'), '合并', expectedRevisionId: head);
      expect(saved.error?.code, GatewayCode.revisionConflict);
      expect((await gateway.listScheduleRevisions(_term)).data!.length, 3);
    });

    test('等着选的课表：选过保留本地的同一份不再等，教务又变了才再等；每学期只留一份', () async {
      expect((await gateway.holdScheduleSync(_term, _courses('教务新楼'), dismissed: false)).data, isTrue);
      expect((await gateway.readHeldScheduleSyncs()).data!.single.courses.single.meetings.single.place, '教务新楼');
      expect((await gateway.holdScheduleSync(_term, _courses('教务新楼'), dismissed: true)).data, isFalse);
      expect((await gateway.readHeldScheduleSyncs()).data, isEmpty);
      expect((await gateway.holdScheduleSync(_term, _courses('教务新楼'), dismissed: false)).data, isFalse, reason: '同一份选过保留本地');
      expect((await gateway.readHeldScheduleSyncs()).data, isEmpty);
      expect((await gateway.holdScheduleSync(_term, _courses('教务再新楼'), dismissed: false)).data, isTrue, reason: '教务又变了');
      expect((await gateway.readHeldScheduleSyncs()).data!.single.courses.single.meetings.single.place, '教务再新楼');
    });

    test('教务课表落成新版本时等着选的那份作废：整份覆盖、逐项合并都算', () async {
      final head = await eduThenUser();
      await gateway.holdScheduleSync(_term, _courses('教务新楼'), dismissed: false);
      await gateway.commitScheduleSync(_term, _courses('教务新楼'), confirm: true, expectedRevisionId: head);
      expect((await gateway.readHeldScheduleSyncs()).data, isEmpty);

      final next = await database.headRevisionId(_term);
      final mine = await database.saveSchedule(_term, _courses('我又改了'), '改', expectedRevisionId: next, now: 'c');
      await gateway.holdScheduleSync(_term, _courses('教务再新楼'), dismissed: false);
      await gateway.commitScheduleMerge(_term, _courses('教务再新楼'), _courses('合并'), '合并', expectedRevisionId: mine.id);
      expect((await gateway.readHeldScheduleSyncs()).data, isEmpty);
    });

    test('需要确认却没确认的提交被拒时，等着选的那份还在', () async {
      await eduThenUser();
      await gateway.holdScheduleSync(_term, _courses('教务新楼'), dismissed: false);
      expect((await gateway.commitScheduleSync(_term, _courses('教务新楼'), confirm: false)).error?.code, GatewayCode.syncConflict);
      expect((await gateway.readHeldScheduleSyncs()).data, hasLength(1));
    });

    test('设置与上次结果来回存取；没设置过是关着的默认值；不在可选范围的不存', () async {
      final initial = (await gateway.readAutoSync()).data!;
      expect(initial.setting.enabled, isFalse);
      expect(initial.setting.interval, autoSyncDefaultInterval);
      expect(initial.setting.years, isNull);
      expect(initial.status.lastAttemptAt, isNull);

      const setting = AutoSyncSetting(enabled: true, interval: Duration(hours: 6), years: {'2026', '2025'}, contents: {SyncContent.bells});
      expect((await gateway.saveAutoSyncSetting(setting)).ok, isTrue);
      await gateway.recordAutoSync(AutoSyncStatus(lastAttemptAt: now, lastSuccessAt: now, state: AutoSyncState.limited, message: '说明'));
      final read = (await gateway.readAutoSync()).data!;
      expect(read.setting.enabled, isTrue);
      expect(read.setting.interval, const Duration(hours: 6));
      expect(read.setting.years, {'2026', '2025'});
      expect(read.setting.contents, {SyncContent.bells});
      expect(read.status.lastAttemptAt, now);
      expect(read.status.lastSuccessAt, now);
      expect(read.status.state, AutoSyncState.limited);
      expect(read.status.message, '说明');

      // 改设置不动上次结果；学年改回「当前学年」存得回空。
      await gateway.saveAutoSyncSetting(setting.copyWith(years: () => null));
      final again = (await gateway.readAutoSync()).data!;
      expect(again.setting.years, isNull);
      expect(again.status.state, AutoSyncState.limited);

      for (final invalid in const [
        AutoSyncSetting(interval: Duration(minutes: 1)),
        AutoSyncSetting(contents: {}),
        AutoSyncSetting(years: {}),
      ]) {
        expect((await gateway.saveAutoSyncSetting(invalid)).error?.code, GatewayCode.invalidAutoSync);
      }
    });

    test('还没存过设置时记结果不会把开关打开', () async {
      await gateway.recordAutoSync(AutoSyncStatus(lastAttemptAt: now, state: AutoSyncState.ok));
      final read = (await gateway.readAutoSync()).data!;
      expect(read.setting.enabled, isFalse);
      expect(read.status.lastAttemptAt, now);
    });

    test('从 v7 升上来：新表建好，原有数据不动', () async {
      final path = '${directory.path}/old.db';
      final old = await AppDatabase.open(databasePath: path);
      await old.syncSchedule(_term, _courses('教务楼'), confirm: false, now: 'a');
      await old.close();
      // 退回 v7 的样子：没有这两张表。
      final raw = await openDatabase(path);
      await raw.execute('DROP TABLE schedule_sync_hold');
      await raw.execute('DROP TABLE auto_sync');
      await raw.setVersion(7);
      await raw.close();

      final upgraded = await AppDatabase.open(databasePath: path);
      addTearDown(upgraded.close);
      expect((await upgraded.latestEduCourses(_term))!.single.meetings.single.place, '教务楼');
      expect((await upgraded.readAutoSync()).setting.enabled, isFalse);
      expect(await upgraded.heldSchedules(), isEmpty);
      await upgraded.holdSchedule(_term, _courses('教务新楼'), dismissed: false, now: 'b');
      expect(await upgraded.heldSchedules(), hasLength(1));
    });
  });

  group('编排', () {
    late _Gateway gateway;
    late _Scheduler scheduler;
    late AutoSync autoSync;
    setUp(() {
      gateway = _Gateway();
      scheduler = _Scheduler();
      autoSync = AutoSync(gateway: gateway, scheduler: scheduler, clock: () => now);
      gateway.autoSyncSetting = const AutoSyncSetting(enabled: true);
    });

    test('到期才同步，范围取设置里的内容；「当前学年」按本机当前学期取，只同步那一学年', () async {
      gateway.autoSyncStatus = AutoSyncStatus(lastAttemptAt: now.subtract(const Duration(hours: 1)));
      await autoSync.runIfDue();
      expect(gateway.synced, isEmpty, reason: '没到间隔');

      gateway.autoSyncStatus = AutoSyncStatus(lastAttemptAt: now.subtract(const Duration(days: 2)));
      await autoSync.runIfDue();
      expect(gateway.synced, [_term.key]);
      expect(gateway.gradeTerms, [_term.key]);
      expect(gateway.autoSyncStatus.state, AutoSyncState.ok);
      expect(gateway.autoSyncStatus.lastAttemptAt, now);
      expect(gateway.autoSyncStatus.lastSuccessAt, now);
    });

    test('选了具体学年就只同步选的；没选作息就不碰作息', () async {
      gateway.autoSyncSetting = const AutoSyncSetting(enabled: true, years: {'2025'}, contents: {SyncContent.schedule});
      await autoSync.runIfDue();
      expect(gateway.synced, ['2025-1']);
      expect(gateway.gradeTerms, isEmpty);
      expect(gateway.bellsCalls, 0);
    });

    test('同步期间改了设置：这轮结束时不把内存里的设置改回旧值', () async {
      gateway.autoSyncSetting = const AutoSyncSetting(enabled: true, contents: {SyncContent.schedule});
      await autoSync.accountChanged(signedIn: true);
      gateway.onSchedule = () async {
        gateway.onSchedule = null;
        await autoSync.save(const AutoSyncSetting(enabled: true, interval: Duration(days: 7), contents: {SyncContent.schedule}));
      };
      await autoSync.runIfDue();
      expect(autoSync.view!.setting.interval, const Duration(days: 7));
      expect(autoSync.view!.status.state, AutoSyncState.ok);
    });

    test('开关关着不联网', () async {
      gateway.autoSyncSetting = const AutoSyncSetting();
      await autoSync.runIfDue();
      expect(gateway.termCalls, 0);
    });

    test('有别的同步在跑就这次不跑；跑到一半有人手动同步就让路', () async {
      final manual = CampusSync(gateway);
      gateway.onSchedule = () async => autoSync.runIfDue();
      await manual.run(contents: {SyncContent.schedule}, years: {'2026'}, isActive: () => true, resolveSchedule: (_, _, _) async => const KeepLocal(remember: true), chooseBells: (_, _) async => BellsChoice.cancel);
      expect(gateway.termCalls, 1, reason: '只有手动那一轮刷了学期');
      expect(gateway.autoSyncStatus.lastAttemptAt, isNull);

      gateway.onSchedule = null;
      gateway.autoSyncSetting = const AutoSyncSetting(enabled: true, years: {'2026', '2025'}, contents: {SyncContent.schedule});
      Future<CampusSyncReport>? yielded;
      gateway.onSchedule = () async {
        gateway.onSchedule = null;
        yielded = CampusSync(gateway).run(contents: {SyncContent.grades}, years: {'2026'}, isActive: () => true, resolveSchedule: (_, _, _) async => const KeepLocal(remember: true), chooseBells: (_, _) async => BellsChoice.cancel);
      };
      gateway.synced.clear();
      await autoSync.runIfDue();
      await yielded;
      expect(gateway.synced, hasLength(1), reason: '第二学期不再同步');
    });

    test('教务确有新改动的冲突不覆盖，留到打扰时机问', () async {
      gateway.conflict = SyncPlan(conflict: true, action: 'needs_confirm', revisionId: 'mine', base: _courses('教务楼'));
      gateway.edu = _courses('教务新楼');
      await autoSync.runIfDue();
      expect(gateway.commits, 0);
      expect(autoSync.held.single.term.key, _term.key);
      expect(autoSync.held.single.courses.single.meetings.single.place, '教务新楼');
      expect(gateway.autoSyncStatus.state, AutoSyncState.ok);

      final moments = AppMoments(autoSync: autoSync, timetable: () async => const CampusTimetable(<CourseOccurrence>[]), clock: () => now);
      addTearDown(moments.dispose);
      final moment = await moments.next();
      expect(moment, isA<SyncConflictMoment>());
      moments.begin(moment!);
      expect(await moments.next(), isNull, reason: '这次前台用掉了');
      moments.foreground();
      expect(await moments.next(), isA<SyncConflictMoment>(), reason: '没选就下个打扰时机再问');
    });

    test('教务和上次同步的一样（只是你自己改过）：悄悄保留本地，不打扰', () async {
      gateway.conflict = SyncPlan(conflict: true, action: 'needs_confirm', revisionId: 'mine', base: _courses('教务楼'));
      gateway.edu = _courses('教务楼');
      await autoSync.runIfDue();
      expect(gateway.commits, 0);
      expect(autoSync.held, isEmpty);
    });

    test('上下课安静期里冲突也不弹', () async {
      gateway.conflict = SyncPlan(conflict: true, action: 'needs_confirm', revisionId: 'mine', base: _courses('教务楼'));
      gateway.edu = _courses('教务新楼');
      await autoSync.runIfDue();
      final moments = AppMoments(
        autoSync: autoSync,
        timetable: () async => CampusTimetable([_occurrenceAround(now)]),
        clock: () => now,
      );
      addTearDown(moments.dispose);
      expect(await moments.next(), isNull);
    });

    test('自动同步不改作息来源：需要确认采用别的学期时跳过', () async {
      gateway.autoSyncSetting = const AutoSyncSetting(enabled: true, contents: {SyncContent.bells});
      await autoSync.runIfDue();
      expect(gateway.bellsCalls, greaterThan(0));
      expect(gateway.adopted, isFalse);
    });

    test('登录过期：只暂停，后台不再联网；冷启动不清暂停（会话是不是有效还不知道），重新登录才清', () async {
      gateway.failSchedule = GatewayCode.sessionExpired;
      await autoSync.runIfDue();
      expect(gateway.autoSyncStatus.state, AutoSyncState.paused);
      expect(gateway.autoSyncStatus.message, contains('重新登录'));

      gateway.failSchedule = null;
      gateway.synced.clear();
      gateway.autoSyncStatus = AutoSyncStatus(lastAttemptAt: now.subtract(const Duration(days: 9)), state: AutoSyncState.paused, message: gateway.autoSyncStatus.message);
      await autoSync.runIfDue();
      expect(gateway.synced, isEmpty, reason: '后台暂停着不联网');

      await autoSync.accountChanged(signedIn: true);
      expect(gateway.autoSyncStatus.state, AutoSyncState.paused, reason: '冷启动只是读回本机会话');
      expect(autoSync.view!.status.message, contains('重新登录'), reason: '设置页照样写明');

      await autoSync.accountChanged(signedIn: true, relogin: true);
      expect(gateway.autoSyncStatus.state, isNull);
      await autoSync.runIfDue();
      expect(gateway.synced, [_term.key], reason: '重新登录后后台接着跑');
    });

    test('暂停时用户打开应用到了间隔就试一次：会话其实有效就恢复，还是过期就接着暂停、不多试', () async {
      gateway.autoSyncStatus = AutoSyncStatus(lastAttemptAt: now.subtract(const Duration(days: 2)), state: AutoSyncState.paused, message: '合成');
      await autoSync.runIfDue(foreground: true);
      expect(gateway.synced, [_term.key]);
      expect(gateway.autoSyncStatus.state, AutoSyncState.ok);

      gateway.synced.clear();
      gateway.failSchedule = GatewayCode.sessionExpired;
      gateway.autoSyncStatus = AutoSyncStatus(lastAttemptAt: now.subtract(const Duration(days: 2)), state: AutoSyncState.paused, message: '合成');
      await autoSync.runIfDue(foreground: true);
      expect(gateway.autoSyncStatus.state, AutoSyncState.paused);
      expect(gateway.autoSyncStatus.lastAttemptAt, now);
      gateway.synced.clear();
      await autoSync.runIfDue(foreground: true);
      expect(gateway.synced, isEmpty, reason: '没到间隔不再试');
    });

    test('没连上网记成 network，隔一会儿能再试；限流记成 limited，到下次间隔再说', () async {
      gateway.failSchedule = GatewayCode.networkFailed;
      await autoSync.runIfDue();
      expect(gateway.autoSyncStatus.state, AutoSyncState.network);
      expect(gateway.autoSyncStatus.lastSuccessAt, isNull);

      gateway.autoSyncStatus = const AutoSyncStatus();
      gateway.failSchedule = GatewayCode.rateLimited;
      await autoSync.runIfDue();
      expect(gateway.autoSyncStatus.state, AutoSyncState.limited);
    });

    test('别的失败记成 failed 并写明哪一项；上次成功的时刻留着', () async {
      gateway.autoSyncStatus = AutoSyncStatus(lastSuccessAt: now.subtract(const Duration(days: 9)));
      gateway.failSchedule = GatewayCode.upstreamFormat;
      await autoSync.runIfDue();
      expect(gateway.autoSyncStatus.state, AutoSyncState.failed);
      expect(gateway.autoSyncStatus.message, contains('课表'));
      expect(gateway.autoSyncStatus.lastSuccessAt, now.subtract(const Duration(days: 9)));
    });

    test('还没有学期时不联网，写明先手动同步一次', () async {
      gateway.terms = const [];
      await autoSync.runIfDue();
      expect(gateway.termCalls, 0);
      expect(gateway.autoSyncStatus.state, AutoSyncState.failed);
      expect(gateway.autoSyncStatus.message, contains('手动同步'));
    });

    test('后台任务跟着设置走：开着按间隔排（第一次排在到期时）、关着撤掉、退出登录撤掉', () async {
      gateway.autoSyncStatus = AutoSyncStatus(lastAttemptAt: now.subtract(const Duration(hours: 6)));
      await autoSync.accountChanged(signedIn: true);
      expect(scheduler.calls, ['schedule ${const Duration(days: 1)} ${const Duration(hours: 18)}']);

      scheduler.calls.clear();
      expect(await autoSync.save(const AutoSyncSetting(enabled: true, interval: Duration(hours: 6))), isNull);
      expect(scheduler.calls, ['schedule ${const Duration(hours: 6)} ${Duration.zero}']);

      scheduler.calls.clear();
      expect(await autoSync.save(const AutoSyncSetting()), isNull);
      expect(scheduler.calls, ['cancel']);

      scheduler.calls.clear();
      await autoSync.accountChanged(signedIn: false);
      expect(scheduler.calls, ['cancel']);
      expect(autoSync.view, isNull);
    });

    test('系统接口出错只记日志，设置照样存着', () async {
      scheduler.fails = true;
      expect(await autoSync.save(const AutoSyncSetting(enabled: true, interval: Duration(hours: 6))), isNull);
      expect(gateway.autoSyncSetting.interval, const Duration(hours: 6));
    });

    test('设置存不进去时返回原因，不动后台任务', () async {
      expect(await autoSync.save(const AutoSyncSetting(interval: Duration(minutes: 1))), isNotNull);
      expect(scheduler.calls, isEmpty);
    });

    test('打扰时机里选了：按选择落库，等着选的那份没了', () async {
      gateway.conflict = SyncPlan(conflict: true, action: 'needs_confirm', revisionId: 'mine', base: _courses('教务楼'));
      gateway.edu = _courses('教务新楼');
      await autoSync.runIfDue();
      final held = autoSync.held.single;
      final kept = await autoSync.settle(held, const KeepLocal(remember: true), expectedRevisionId: null);
      expect(kept.outcome, SyncOutcome.skipped);
      expect(autoSync.held, isEmpty);
    });
  });
}

CourseOccurrence _occurrenceAround(DateTime now) => CourseOccurrence(
  course: _courses('合成楼').single,
  meeting: _courses('合成楼').single.meetings.single,
  date: '2026-11-05',
  start: now.add(const Duration(minutes: 10)),
  end: now.add(const Duration(minutes: 55)),
);

class _Scheduler implements BackgroundSyncScheduler {
  final calls = <String>[];
  bool fails = false;
  @override
  Future<void> schedule(Duration interval, {required Duration delay}) async {
    if (fails) throw StateError('合成的系统错误');
    calls.add('schedule $interval $delay');
  }

  @override
  Future<void> cancel() async {
    if (fails) throw StateError('合成的系统错误');
    calls.add('cancel');
  }
}

class _Gateway extends FixtureCampusGateway {
  _Gateway() : super(readText: (name) => File('assets/fixtures/$name').readAsString());
  List<TermRef> terms = const [_term, TermRef(xn: '2025', xq: '1', label: '上学年')];
  final synced = <String>[];
  final gradeTerms = <String>[];
  int termCalls = 0;
  int bellsCalls = 0;
  int commits = 0;
  bool adopted = false;
  SyncPlan? conflict;
  List<CourseRecord> edu = _courses('教务楼');
  String? failSchedule;
  Future<void> Function()? onSchedule;

  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => _ok(terms);
  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() async {
    termCalls++;
    return _ok(terms);
  }

  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) async {
    synced.add(term.key);
    await onSchedule?.call();
    if (failSchedule case final code?) return _fail(code);
    return _ok(ScheduleView(term: term, student: _student, courses: edu));
  }

  @override
  Future<GatewayResult<SyncPlan>> planScheduleSync(TermRef term, List<CourseRecord> courses) async => _ok(conflict ?? const SyncPlan(conflict: false, action: 'insert'));
  @override
  Future<GatewayResult<RevisionView>> commitScheduleSync(TermRef term, List<CourseRecord> courses, {required bool confirm, String? expectedRevisionId}) async {
    commits++;
    return _ok(const RevisionView(id: 'rev', source: 'edu', createdAt: 'stamp', summary: '同步'));
  }

  @override
  Future<GatewayResult<GradesView>> syncGrades(TermRef term) async {
    gradeTerms.add(term.key);
    return _ok(GradesView(empty: true, message: '', term: term, student: _student, summary: null, effective: const [], original: const []));
  }

  @override
  Future<GatewayResult<BellsView>> syncBells(TermRef term) async {
    bellsCalls++;
    return _ok(BellsView(empty: true, message: '', term: term, periods: const []));
  }

  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async => _ok(BellsView(empty: false, message: '', term: term, periods: const [BellPeriod(period: 1, dayPart: '上午', dayPartCode: 'morning', start: '08:00', end: '08:45')]));
  @override
  Future<GatewayResult<TermRef?>> readBellsSource(TermRef term) async => _ok(null);
  @override
  Future<GatewayResult<TermRef>> useBellsSource(TermRef target, TermRef source) async {
    adopted = true;
    return _ok(source);
  }
}
