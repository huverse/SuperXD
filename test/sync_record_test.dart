import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/sync_record.dart';
import 'package:superxd/local/app_database.dart';
import 'fixture_campus_gateway.dart';

// 同步记录（人工决策见 domain/sync_record.dart，11-16 用户嫌自动同步「只知道同步了一次、不知道同步了什么」）。
const _term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
const _student = SessionView(loginId: '20260000001', name: '合成同学', className: '合成班');

CourseRecord _course(String code, String name, {String teacher = '合成教师甲', int start = 1}) => CourseRecord(
  courseCode: code, courseName: name, sectionId: '$code-01', credit: 2, teacherName: teacher,
  meetings: [CourseMeeting(weekday: 1, periodStart: start, periodEnd: start + 1, place: '合成楼101', weeks: const [1, 2, 3])],
);

GatewayResult<T> ok<T>(T data) => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: data);

GradeCourse _grade(String code, String name, Object score) => GradeCourse(courseCode: code, courseName: name, credit: 2, score: score);

GradesView _grades(List<GradeCourse> effective, {bool cached = true}) =>
    GradesView(empty: effective.isEmpty, message: '', term: _term, student: _student, summary: null, effective: effective, original: const [], cached: cached);

// 同步前本机：课表甲乙两门（版本 r1）、成绩一门；教务这次：甲换了老师、乙没了、新加丙，成绩多出一门、原来那门改了分。
class _Gateway extends FixtureCampusGateway {
  _Gateway() : super(readText: (name) => File('assets/fixtures/$name').readAsString());
  List<CourseRecord> local = [_course('A', '合成高数'), _course('B', '合成英语')];
  String? localRevision = 'r1';
  List<CourseRecord> edu = [_course('A', '合成高数', teacher: '合成教师乙'), _course('C', '合成物理', start: 3)];
  GradesView localGrades = _grades([_grade('X', '合成线代', 80)]);
  GradesView eduGrades = _grades([_grade('X', '合成线代', 82), _grade('Y', '合成概率', 90)]);
  bool conflict = false;

  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() async => ok([_term]);
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => ok([_term]);
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async => ok(ScheduleView(term: _term, student: _student, courses: local, revisionId: localRevision));
  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) async => ok(ScheduleView(term: term, student: _student, courses: edu));
  @override
  Future<GatewayResult<SyncPlan>> planScheduleSync(TermRef term, List<CourseRecord> courses) async =>
      ok(SyncPlan(conflict: conflict, action: conflict ? 'needs_confirm' : 'insert', revisionId: localRevision));
  @override
  Future<GatewayResult<RevisionView>> commitScheduleSync(TermRef term, List<CourseRecord> courses, {required bool confirm, String? expectedRevisionId}) async {
    local = courses;
    localRevision = 'r2';
    return ok(const RevisionView(id: 'r2', source: 'edu', createdAt: 'stamp', summary: '同步'));
  }
  @override
  Future<GatewayResult<bool>> holdScheduleSync(TermRef term, List<CourseRecord> courses, {required bool dismissed}) async => ok(!dismissed);
  @override
  Future<GatewayResult<GradesView>> readGrades(TermRef term) async => ok(localGrades);
  @override
  Future<GatewayResult<GradesView>> syncGrades(TermRef term) async => ok(eduGrades);
}

class _Notices implements SyncNotices {
  final shown = <SyncRecord>[];
  @override
  Future<void> show(SyncRecord record) async => shown.add(record);
  @override
  Future<bool> request() async => true;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('记录的读写边界：名字与条数有上限，读到坏项跳过、坏 JSON 当没有变化', () {
    final names = [for (var index = 0; index < 50; index++) '课${'名' * index}'];
    final record = SyncRecord(at: DateTime.utc(2026, 11, 16), trigger: SyncTrigger.auto, changes: [
      ScheduleSyncChange(termKey: _term.key, termLabel: _term.label, added: names, counts: (50, 0, 0), before: 'r1'),
      GradeSyncChange(termKey: _term.key, termLabel: _term.label, added: const ['合成概率 90'], counts: (1, 0)),
    ]);
    final read = SyncRecord.fromRow(id: 7, at: '2026-11-16T00:00:00.000Z', trigger: 'auto', payload: jsonEncodeRecord(record));
    final schedule = read.changes.first as ScheduleSyncChange;
    expect(schedule.added, hasLength(syncRecordNames));
    expect(schedule.added.every((name) => name.length <= 60), isTrue);
    expect((schedule.counts, schedule.before, read.trigger, read.id), ((50, 0, 0), 'r1', SyncTrigger.auto, 7));
    expect((read.changes.last as GradeSyncChange).added, ['合成概率 90']);
    final junk = SyncRecord.fromRow(id: 1, at: '2026-11-16T00:00:00.000Z', trigger: 'nope', payload: '{"changes":[{"kind":"what"},{"kind":"grades","term":3}],"failures":[1,"成绩：超时"]}');
    expect(junk.changes, isEmpty);
    expect(junk.failures, ['成绩：超时']);
    expect(junk.trigger, SyncTrigger.manual);
    expect(SyncRecord.fromRow(id: 2, at: '2026-11-16T00:00:00.000Z', trigger: 'auto', payload: '[]').changes, isEmpty);
  });

  test('文案与通知：只有自动同步、且不是第一次同步到的变化才发通知；成绩写课名，等你来选的另说', () {
    SyncRecord auto(List<SyncChange> changes, {SyncTrigger trigger = SyncTrigger.auto}) => SyncRecord(at: DateTime.utc(2026, 11, 16), trigger: trigger, changes: changes);
    final grades = GradeSyncChange(termKey: _term.key, termLabel: _term.label, added: const ['合成概率 90', '合成线代 82'], counts: (2, 0));
    expect(syncRecordNotice(auto([grades])), (title: '新出了 2 门成绩', body: '合成概率 90、合成线代 82'));
    expect(syncRecordNotice(auto([grades], trigger: SyncTrigger.manual)), isNull, reason: '手动同步的人就在看结果');
    expect(syncRecordNotice(auto([GradeSyncChange(termKey: _term.key, termLabel: _term.label, counts: (40, 0), first: true)])), isNull, reason: '第一次同步到的不算有变化');
    final held = ScheduleSyncChange(termKey: _term.key, termLabel: _term.label, counts: (1, 0, 1), held: true);
    expect(syncRecordNotice(auto([held]))?.title, '教务课表有改动，等你来选');
    expect(syncChangeLine(held), '课表 · 2026-2027学年第一学期 · 教务有改动，和你改过的不一样，等你来选');
    expect(syncChangeLine(ScheduleSyncChange(termKey: _term.key, termLabel: _term.label, counts: (1, 1, 2))), '课表 · 2026-2027学年第一学期 · 新增 1 门、删除 1 门、改动 2 门');
    expect(syncRecordHeadline(auto([])), '没有变化');
    // 11-19：只有课表变了写「课表有更新」，只改了分数写「成绩有改动」，两类都变才写「课表、成绩有更新」。
    final schedule = ScheduleSyncChange(termKey: _term.key, termLabel: _term.label, counts: (1, 0, 0), before: 'r1');
    final regraded = GradeSyncChange(termKey: _term.key, termLabel: _term.label, changed: const ['合成线代 82'], counts: (0, 1));
    expect(syncRecordNotice(auto([schedule]))?.title, '课表有更新');
    expect(syncRecordNotice(auto([regraded]))?.title, '成绩有改动');
    expect(syncRecordNotice(auto([schedule, regraded]))?.title, '课表、成绩有更新');
    // 比对过、和上次一样的逐项记下：概括写查了哪几类。
    SyncRecord same(List<String> items) => SyncRecord(at: DateTime.utc(2026, 11, 16), trigger: SyncTrigger.auto, same: items);
    expect(syncRecordHeadline(same(['课表 · ${_term.label}', '成绩 · ${_term.label}'])), '课表、成绩都和上次一样');
    expect(syncRecordHeadline(same(['成绩 · ${_term.label}'])), '成绩和上次一样');
    expect(SyncRecord.fromRow(id: 3, at: '2026-11-16T00:00:00.000Z', trigger: 'auto', payload: jsonEncodeRecord(same(['课表 · ${_term.label}']))).same, ['课表 · ${_term.label}']);
    expect(syncRecordHeadline(SyncRecord(at: DateTime.utc(2026), trigger: SyncTrigger.auto, failures: const ['成绩 · 2026-2027学年第一学期：学校教务系统没有响应'])), '没有同步完：成绩 · 2026-2027学年第一学期：学校教务系统没有响应');
  });

  test('本机账号库：每轮一行，写入时删到只剩最新 50 行，读出来从新到旧', () async {
    final database = await AppDatabase.openMemory();
    for (var index = 0; index < 55; index++) {
      await database.insertSyncRecord(SyncRecord(at: DateTime.utc(2026, 11, 16, 0, index), trigger: SyncTrigger.manual, failures: ['第 $index 次']));
    }
    final records = await database.syncRecords();
    expect(records, hasLength(syncRecordLimit));
    expect(records.first.failures, ['第 54 次']);
    expect(records.last.failures, ['第 5 次']);
  });

  group('同步编排记下这一轮改了什么', () {
    test('课表新增、删除、改动与同步前那一版，成绩新出与改了分；手动同步记成手动', () async {
      final gateway = _Gateway();
      final report = await CampusSync(gateway).run(
        contents: {SyncContent.schedule, SyncContent.grades},
        isActive: () => true,
        resolveSchedule: (_, _, _) async => const KeepLocal(remember: true),
        chooseBells: (_, _) async => BellsChoice.cancel,
      );
      final record = report.record!;
      expect(record.trigger, SyncTrigger.manual);
      expect(gateway.syncRecords.single.id, record.id, reason: '记进了账号库');
      final schedule = record.changes.whereType<ScheduleSyncChange>().single;
      expect([schedule.added, schedule.removed, schedule.changed], [['合成物理'], ['合成英语'], ['合成高数：教师']]);
      expect((schedule.counts, schedule.before, schedule.first), ((1, 1, 1), 'r1', false));
      final grades = record.changes.whereType<GradeSyncChange>().single;
      expect([grades.added, grades.changed], [['合成概率 90'], ['合成线代 82']]);
      expect(record.changed, isTrue);
    });

    test('本机原来没有这学期：记成第一次，不算有变化；教务和本机一样：不记变化，只留一条「没有变化」', () async {
      final first = _Gateway()
        ..localRevision = null
        ..localGrades = _grades(const [], cached: false);
      final report = await CampusSync(first).run(contents: {SyncContent.schedule, SyncContent.grades}, isActive: () => true, resolveSchedule: (_, _, _) async => const KeepLocal(remember: true), chooseBells: (_, _) async => BellsChoice.cancel);
      expect([for (final change in report.record!.changes) switch (change) { ScheduleSyncChange(:final first) => first, GradeSyncChange(:final first) => first }], [true, true]);
      expect(report.record!.changed, isFalse);
      final same = _Gateway()
        ..edu = [_course('A', '合成高数'), _course('B', '合成英语')]
        ..eduGrades = _grades([_grade('X', '合成线代', 80)]);
      final quiet = await CampusSync(same).run(contents: {SyncContent.schedule, SyncContent.grades}, isActive: () => true, resolveSchedule: (_, _, _) async => const KeepLocal(remember: true), chooseBells: (_, _) async => BellsChoice.cancel);
      expect(quiet.record!.changes, isEmpty);
      expect(quiet.record!.same, ['课表 · ${_term.label}', '成绩 · ${_term.label}'], reason: '记下比对过、和上次一样的几项');
      expect(syncRecordHeadline(quiet.record!), '课表、成绩都和上次一样');
      expect(report.record!.same, isEmpty, reason: '第一次同步到的记成变化，不算一样');
    });

    test('自动同步记成自动；和你改过的课表冲突、留着等你来选的记成待处理，有变化时发通知', () async {
      final gateway = _Gateway()
        ..conflict = true
        ..autoSyncSetting = const AutoSyncSetting(enabled: true, contents: {SyncContent.schedule, SyncContent.grades});
      final notices = _Notices();
      await AutoSync(gateway: gateway, notices: notices).runIfDue(foreground: true);
      final record = gateway.syncRecords.single;
      expect(record.trigger, SyncTrigger.auto);
      final schedule = record.changes.whereType<ScheduleSyncChange>().single;
      expect((schedule.held, schedule.before), (true, null), reason: '没落库，没什么可撤回的');
      expect(notices.shown.single.id, record.id);
      // 第二轮教务和本机都没新变化：照样留记录，不发通知。
      gateway
        ..conflict = false
        ..edu = gateway.local
        ..eduGrades = gateway.localGrades
        ..autoSyncStatus = const AutoSyncStatus();
      await AutoSync(gateway: gateway, notices: notices).runIfDue(foreground: true);
      expect(gateway.syncRecords, hasLength(2));
      expect(notices.shown, hasLength(1));
    });
  });
}

String jsonEncodeRecord(SyncRecord record) => const JsonEncoder().convert(record.toJson());
