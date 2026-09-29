import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/gateway/fixture_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';

const current = TermRef(xn: '2026', xq: '0', label: '当前学期');
const previous = TermRef(xn: '2025', xq: '1', label: '上学期');
const oldest = TermRef(xn: '2025', xq: '0', label: '第一学期');
const student = SessionView(loginId: 'test', name: '', className: '');

GatewayResult<T> ok<T>(T data) => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: data);
GatewayResult<T> fail<T>(String code) => GatewayResult(ok: false, source: 'edu', fetchedAt: 'stamp', error: GatewayError(code: code, message: code));

void main() {
  test('进度只反映真实任务和待确认，不额外同步或生成百分比', () async {
    final gateway = _Gateway();
    final progress = <CampusSyncProgress>[];
    await CampusSync(gateway).run(contents: {SyncContent.schedule}, years: {'2025'}, isActive: () => true,
      confirmSchedule: (_, _) async { expect(progress.last.waitingForInput, isTrue); return false; },
      chooseBells: (_, _) async => BellsChoice.cancel, onProgress: progress.add);
    expect(progress.first.label, '正在刷新学期列表');
    expect(progress.any((item) => item.label.contains(oldest.label)), isTrue);
    expect(progress.any((item) => item.label.contains('%')), isFalse);
    expect(gateway.synced, [previous.key, oldest.key]);
    expect(gateway.gradesRequests, 0);
  });
  test('全学期去重、失败继续、冲突取消不提交、只有选择项才执行', () async {
    final gateway = _Gateway()..failedTerm = previous.key;
    final report = await CampusSync(gateway).run(contents: {SyncContent.schedule}, isActive: () => true,
      confirmSchedule: (_, _) async => false, chooseBells: (_, _) async => BellsChoice.cancel);
    expect(gateway.synced, [current.key, previous.key, oldest.key]);
    expect(report.items.map((item) => item.outcome), [SyncOutcome.completed, SyncOutcome.failed, SyncOutcome.skipped]);
    expect(gateway.commits, 1);
    expect(gateway.confirmedCommits, 0);
    expect(gateway.bellsRequests, 0);
    expect(gateway.gradesRequests, 0);
  });

  test('取消之后可再次覆盖且检查提交错误', () async {
    final gateway = _Gateway()..commitFails = true;
    final report = await CampusSync(gateway).run(contents: {SyncContent.schedule}, isActive: () => true,
      confirmSchedule: (_, _) async => true, chooseBells: (_, _) async => BellsChoice.cancel);
    expect(gateway.commits, 3);
    expect(gateway.confirmedCommits, 1);
    expect(report.items.last.code, 'SYNC_CONFLICT');
  });

  test('会话失效立即中止，后续学期与成绩都不请求', () async {
    final gateway = _Gateway()..failedTerm = current.key..errorCode = 'SESSION_EXPIRED';
    final report = await CampusSync(gateway).run(contents: SyncContent.values.toSet(), isActive: () => true,
      confirmSchedule: (_, _) async => true, chooseBells: (_, _) async => BellsChoice.use);
    expect(report.sessionExpired, isTrue);
    expect(gateway.synced, [current.key]);
    expect(gateway.gradesRequests, 0);
    expect(gateway.bellsRequests, 0);
  });

  test('采用作息确实调用写入；下一轮保持绑定，不重复询问', () async {
    final gateway = _Gateway();
    final service = CampusSync(gateway);
    var prompts = 0;
    Future<BellsChoice> choose(TermRef term, BellsView view) async {
      prompts++;
      expect(term.key, current.key);
      expect(view.term.key, previous.key);
      expect(view.periods.single.start, '08:00');
      return BellsChoice.use;
    }
    await service.run(contents: {SyncContent.bells}, years: {'2026'}, isActive: () => true, confirmSchedule: (_, _) async => false, chooseBells: choose);
    expect(gateway.adopted?.key, previous.key);
    await service.run(contents: {SyncContent.bells}, years: {'2026'}, isActive: () => true, confirmSchedule: (_, _) async => false, chooseBells: choose);
    expect(prompts, 1);
    expect(gateway.bellsRequests, 2);
    expect(gateway.synced, isEmpty);
  });

  test('暂不采用保留来源，关闭确认不算成功', () async {
    final gateway = _Gateway();
    final result = await CampusSync(gateway).run(contents: {SyncContent.bells}, isActive: () => true,
      confirmSchedule: (_, _) async => false, chooseBells: (_, _) async => BellsChoice.cancel);
    expect(result.items.last.outcome, SyncOutcome.skipped);
    expect(gateway.adopted, isNull);
  });

  test('选择2025学年后课表、作息、成绩只对两个已公布学期执行', () async {
    final gateway = _Gateway();
    await CampusSync(gateway).run(contents: SyncContent.values.toSet(), years: {'2025'}, isActive: () => true,
      confirmSchedule: (_, _) async => true, chooseBells: (_, _) async => BellsChoice.cancel);
    expect(gateway.synced, [previous.key, oldest.key]);
    expect(gateway.gradesRequests, 2);
    expect(gateway.gradeTerm?.key, oldest.key);
    expect(gateway.bellsRequests, 2);
  });

  test('未选学年不发起同步', () async {
    final gateway = _Gateway();
    final report = await CampusSync(gateway).run(contents: SyncContent.values.toSet(), years: {}, isActive: () => true,
      confirmSchedule: (_, _) async => true, chooseBells: (_, _) async => BellsChoice.cancel);
    expect(report.items, isEmpty);
    expect(gateway.synced, isEmpty);
    expect(gateway.gradesRequests, 0);
  });

  test('同步互斥且异常后锁释放', () async {
    final gateway = _Gateway()..gate = Completer<GatewayResult<List<TermRef>>>();
    final service = CampusSync(gateway);
    Future<CampusSyncReport> run() => service.run(contents: {SyncContent.grades}, isActive: () => true,
      confirmSchedule: (_, _) async => false, chooseBells: (_, _) async => BellsChoice.cancel);
    final first = run();
    expect((await run()).busy, isTrue);
    gateway.gate!.completeError(StateError('local failed'));
    await expectLater(first, throwsStateError);
    gateway.gate = null;
    expect((await run()).busy, isFalse);
    expect(gateway.gradeTerm?.key, oldest.key);
    expect(gateway.gradesRequests, 3);
  });
}

class _Gateway extends FixtureCampusGateway {
  _Gateway() : super(readText: (name) => File('assets/fixtures/$name').readAsString());
  final synced = <String>[];
  String? failedTerm;
  String errorCode = 'NETWORK_TIMEOUT';
  int commits = 0;
  int confirmedCommits = 0;
  int bellsRequests = 0;
  int gradesRequests = 0;
  bool commitFails = false;
  TermRef? gradeTerm;
  TermRef? adopted;
  Completer<GatewayResult<List<TermRef>>>? gate;

  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() async => gate == null ? ok([current, previous, oldest, previous]) : gate!.future;
  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) async {
    synced.add(term.key);
    return term.key == failedTerm ? fail(errorCode) : ok(ScheduleView(term: term, student: student, courses: []));
  }
  @override
  Future<GatewayResult<SyncPlan>> planScheduleSync(TermRef term, List<CourseRecord> courses) async => ok(SyncPlan(conflict: term.key == oldest.key, action: term.key == oldest.key ? 'needs_confirm' : 'unchanged'));
  @override
  Future<GatewayResult<RevisionView>> commitScheduleSync(TermRef term, List<CourseRecord> courses, {required bool confirm, String? expectedRevisionId}) async {
    commits++;
    if (confirm) confirmedCommits++;
    return commitFails ? fail('SYNC_CONFLICT') : ok(const RevisionView(id: 'rev', source: 'edu', createdAt: 'stamp', summary: '同步'));
  }
  @override
  Future<GatewayResult<GradesView>> syncGrades(TermRef term) async {
    gradesRequests++;
    gradeTerm = term;
    return ok(GradesView(empty: true, message: '', term: term, student: student, summary: null, effective: [], original: []));
  }
  @override
  Future<GatewayResult<BellsView>> syncBells(TermRef term) async {
    bellsRequests++;
    return ok(BellsView(empty: true, message: '未设置', term: term, periods: []));
  }
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async => ok(BellsView(empty: false, message: '', term: term, periods: [const BellPeriod(period: 1, dayPart: '上午', dayPartCode: 'morning', start: '08:00', end: '08:45')]));
  @override
  Future<GatewayResult<TermRef?>> readBellsSource(TermRef term) async => ok(term.key == current.key ? adopted : null);
  @override
  Future<GatewayResult<TermRef>> useBellsSource(TermRef target, TermRef source) async {
    adopted = source;
    return ok(source);
  }
}
