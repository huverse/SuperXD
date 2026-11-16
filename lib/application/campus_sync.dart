import 'dart:async';

import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/gateway_code.dart';
import 'package:superxd/domain/sync_record.dart';

class SyncSelection {
  SyncSelection({required Set<String> years, required Set<SyncContent> contents})
      : years = Set.unmodifiable(years), contents = Set.unmodifiable(contents);
  final Set<String> years;
  final Set<SyncContent> contents;
  bool get valid => years.isNotEmpty && contents.isNotEmpty;
}
enum SyncOutcome { completed, skipped, failed }
enum BellsChoice { use, next, cancel }

// 教务课表和本地改过的版本冲突时怎么办（三方合并与自动同步的人工决策见 domain/auto_sync.dart）。
sealed class ScheduleResolution {
  const ScheduleResolution();
}

// 留着本地版本：remember 为真时记下这份教务课表、同一份不再提醒（选了保留本地、或退出合并页）；为假时留到打扰时机再问（自动同步）。
class KeepLocal extends ScheduleResolution {
  const KeepLocal({required this.remember});
  final bool remember;
}

// 整份换成教务课表。
class TakeEdu extends ScheduleResolution {
  const TakeEdu();
}

// 逐项合并：merged 是合并后的课表，summary 写进历史版本。
class MergeEdu extends ScheduleResolution {
  const MergeEdu(this.merged, this.summary);
  final List<CourseRecord> merged;
  final String summary;
}

class SyncItemResult {
  const SyncItemResult(this.label, this.outcome, this.message, {this.code});
  final String label;
  final SyncOutcome outcome;
  final String message;
  final String? code;
}

class CampusSyncReport {
  const CampusSyncReport(this.items, {this.busy = false, this.cancelled = false, this.unfinished = const [], this.record});
  final List<SyncItemResult> items;
  // 这一轮记下的同步记录（人工决策见 domain/sync_record.dart）；没做任何事或没记成时为空。
  final SyncRecord? record;
  final bool busy;
  final bool cancelled;
  // 提前结束时尚未处理的同步项，按原执行顺序排列。
  final List<String> unfinished;
  bool get sessionExpired => items.any((item) => item.code == GatewayCode.sessionExpired);
  bool get rateLimited => items.any((item) => item.code == GatewayCode.rateLimited);
}

// [人工决策-2026-09-30 15:18:51] 教务限流与会话失效一样立即停止本轮剩余请求并列出未处理项；限流不转登录、不自动重试，由用户稍后重新同步。
const _stopCodes = {GatewayCode.sessionExpired, GatewayCode.rateLimited};

class CampusSyncProgress {
  const CampusSyncProgress(this.label, {this.waitingForInput = false});
  final String label;
  final bool waitingForInput;
}

class CampusSync {
  CampusSync(this.gateway);
  final CampusGateway gateway;
  bool _running = false;
  // 本进程里正在跑的同步有几轮（各实例合计）：自动同步见到有别的在跑就不开始、开始后有人手动同步就让路。
  static int _active = 0;
  static int get activeRuns => _active;
  // 会让路的那几轮（自动同步）还没收尾的：手动同步先等它们停下再发请求，不然撞上它在途的请求报「成绩同步进行中」。
  static final _yielding = <Future<void>>{};

  // [人工决策-2026-09-24 21:39:35] 用户先多选学年与同步项，三类数据统一范围；跨学年作息来源仍须明确确认。
  // 每一轮做完（含中途停下）记一条同步记录：自动同步（yields）记成自动，其余记成手动（人工决策见 domain/sync_record.dart）。
  Future<CampusSyncReport> run({
    required Set<SyncContent> contents,
    Set<String>? years,
    required Future<ScheduleResolution> Function(TermRef term, SyncPlan plan, List<CourseRecord> courses) resolveSchedule,
    required Future<BellsChoice> Function(TermRef target, BellsView source) chooseBells,
    required bool Function() isActive,
    void Function(CampusSyncProgress progress)? onProgress,
    bool yields = false,
  }) async {
    final changes = <SyncChange>[];
    final report = await _run(contents: contents, years: years, resolveSchedule: resolveSchedule, chooseBells: chooseBells, isActive: isActive, onProgress: onProgress, yields: yields, changes: changes);
    if (report.busy || (report.items.isEmpty && changes.isEmpty)) return report;
    final record = await _record(SyncRecord(
      at: DateTime.now().toUtc(),
      trigger: yields ? SyncTrigger.auto : SyncTrigger.manual,
      changes: changes,
      failures: [for (final item in report.items) if (item.outcome == SyncOutcome.failed) '${item.label}：${item.message}'],
      cancelled: report.cancelled,
    ));
    return CampusSyncReport(report.items, cancelled: report.cancelled, unfinished: report.unfinished, record: record);
  }

  // 记不成只记日志：同步本身已经落库，不因记录失败报错。
  Future<SyncRecord?> _record(SyncRecord record) async {
    final saved = await gateway.recordSync(record);
    if (!saved.ok) campusLog('[CampusSync] action=record errorType=${saved.error?.code}');
    return saved.data;
  }

  Future<CampusSyncReport> _run({
    required Set<SyncContent> contents,
    Set<String>? years,
    required Future<ScheduleResolution> Function(TermRef term, SyncPlan plan, List<CourseRecord> courses) resolveSchedule,
    required Future<BellsChoice> Function(TermRef target, BellsView source) chooseBells,
    required bool Function() isActive,
    void Function(CampusSyncProgress progress)? onProgress,
    required bool yields,
    required List<SyncChange> changes,
  }) async {
    if (_running) return const CampusSyncReport([], busy: true);
    if (contents.isEmpty || years?.isEmpty == true) return const CampusSyncReport([]);
    _running = true;
    _active++;
    final finished = Completer<void>();
    if (yields) _yielding.add(finished.future);
    final items = <SyncItemResult>[];
    try {
      // 自动同步见到 activeRuns 变成 2 就在下一检查点停下；等它把手上那个请求收完。
      if (!yields && _yielding.isNotEmpty) {
        onProgress?.call(const CampusSyncProgress('正在等自动同步停下'));
        await Future.wait([..._yielding]);
      }
      // 显式同步才刷新学期，防止本地列表过期导致漏同步新学期。
      // [人工决策-2026-09-25 14:45:43] 进度只报告已有任务阶段，不改同步范围、顺序和确认规则，不生成假百分比。
      onProgress?.call(const CampusSyncProgress('正在刷新学期列表'));
      final listed = await gateway.syncTerms();
      // [人工决策-2026-09-30 03:14:15] 离开前已拿到的失败照常写入报告，“同步已中止”同时显示失败原因；会话失效仍按原规则提示重新登录。
      final failed = !listed.ok || listed.data == null;
      if (failed) items.add(_failure('学期列表', listed.error));
      if (!isActive()) return CampusSyncReport(items, cancelled: true, unfinished: const ['所选学年的全部内容']);
      if (failed) return CampusSyncReport(items);
      final allTerms = {for (final term in listed.data!) term.key: term}.values.toList();
      final terms = allTerms.where((term) => years == null || years.contains(term.xn)).toList();
      if (terms.isEmpty) {
        items.add(const SyncItemResult('学期列表', SyncOutcome.failed, '教务未提供可同步的学期'));
        return CampusSyncReport(items, cancelled: !isActive());
      }
      // 待办按执行顺序登记，处理完一项移除一项；提前结束时把剩余项带给页面提示，可重新同步。
      final pending = [
        if (contents.contains(SyncContent.schedule))
          for (final term in terms) '课表 · ${term.label.isEmpty ? term.key : term.label}',
        for (final term in terms) ...[
          if (contents.contains(SyncContent.bells)) '作息 · ${term.label.isEmpty ? term.key : term.label}',
          if (contents.contains(SyncContent.grades)) '成绩 · ${term.label.isEmpty ? term.key : term.label}',
        ],
      ];
      CampusSyncReport stop(bool cancelled) => CampusSyncReport(items, cancelled: cancelled, unfinished: List.unmodifiable(pending));
      // 同一教务会话顺序请求，避免公共页和私有页并发改 cookie；不自动重试。
      if (contents.contains(SyncContent.schedule)) {
        for (final term in terms) {
          if (!isActive()) return stop(true);
          final label = '课表 · ${term.label.isEmpty ? term.key : term.label}';
          onProgress?.call(CampusSyncProgress('正在同步$label'));
          // 同步前本机这学期的课表：之后对比出改了什么，撤回时恢复它。
          final before = (await gateway.readSchedule(ScheduleScope.term(term))).data;
          final fetched = await gateway.syncSchedule(term);
          if (!fetched.ok || fetched.data == null) {
            items.add(_failure(label, fetched.error));
          } else {
            if (!isActive()) return stop(true);
            final plan = await gateway.planScheduleSync(term, fetched.data!.courses);
            if (!isActive()) return stop(true);
            if (!plan.ok || plan.data == null) {
              items.add(_failure(label, plan.error));
            } else if (plan.data!.conflict) {
              if (!isActive()) return stop(true);
              onProgress?.call(CampusSyncProgress('等待确认$label', waitingForInput: true));
              final resolution = await resolveSchedule(term, plan.data!, fetched.data!.courses);
              onProgress?.call(CampusSyncProgress('正在保存$label'));
              if (!isActive()) return stop(true);
              final settled = await settle(term, fetched.data!.courses, resolution, expectedRevisionId: plan.data!.revisionId);
              items.add(settled);
              final change = _settledChange(term, before, fetched.data!.courses, resolution, settled);
              if (change != null) changes.add(change);
            } else {
              // [人工决策-2026-09-25 00:19:22] 沿用学年/数据项选择；再次提交在事务内核对实时head，未提交不得报已同步。
              final committed = await gateway.commitScheduleSync(term, fetched.data!.courses, confirm: false);
              items.add(committed.ok
                  ? SyncItemResult(label, SyncOutcome.completed, fetched.data!.courses.isEmpty ? '教务暂无课程，已保存空课表' : '已同步')
                  : _failure(label, committed.error));
              // 落了新版本才算有变化（教务和本机一样时返回的还是原来那一版）。
              if (committed.ok && committed.data?.id != before?.revisionId) {
                final change = scheduleSyncChange(term, before, fetched.data!.courses);
                if (change != null) changes.add(change);
              }
            }
          }
          pending.removeAt(0);
          if (_stopCodes.contains(items.last.code)) return stop(!isActive());
        }
      }
      if (!isActive()) return stop(true);
      for (final term in terms) {
        if (!isActive()) return stop(true);
        if (contents.contains(SyncContent.bells)) {
          onProgress?.call(CampusSyncProgress('正在同步作息 · ${term.label}'));
          await _syncBells(term, allTerms, items, (target, source) async {
            onProgress?.call(CampusSyncProgress('等待确认作息来源', waitingForInput: true));
            final choice = await chooseBells(target, source);
            onProgress?.call(CampusSyncProgress('正在处理作息 · ${target.label}'));
            return choice;
          }, isActive);
          if (!isActive()) return stop(true);
          pending.removeAt(0);
          if (items.any((item) => _stopCodes.contains(item.code))) return stop(!isActive());
        }
        if (!isActive()) return stop(true);
        if (contents.contains(SyncContent.grades)) {
          onProgress?.call(CampusSyncProgress('正在同步成绩 · ${term.label}'));
          final previous = await gateway.readGrades(term);
          final grades = await gateway.syncGrades(term);
          if (grades.ok && grades.data != null) {
            // 本机没同步过这学期时 readGrades 照样成功、cached 为假：当没有原来的，记成第一次。
            final change = gradeSyncChange(term, previous.data?.cached == true ? previous.data : null, grades.data!);
            if (change != null) changes.add(change);
          }
          items.add(grades.ok && grades.data != null
              ? SyncItemResult('成绩 · ${term.label}', SyncOutcome.completed, grades.data!.empty ? '教务暂无成绩，已保存空结果' : '已同步')
              : _failure('成绩 · ${term.label}', grades.error));
          pending.removeAt(0);
          if (_stopCodes.contains(grades.error?.code)) return stop(!isActive());
        }
      }
      return CampusSyncReport(items, cancelled: !isActive());
    } finally {
      _running = false;
      _active--;
      if (yields) {
        _yielding.remove(finished.future);
        finished.complete();
      }
    }
  }

  // 冲突的教务课表按选择落库；同步当中与打扰时机里处理暂存的那份共用。
  // expectedRevisionId 是比对时的当前版本（SyncPlan.revisionId），落库时在事务里核对，期间课表被改过就报冲突、不覆盖。
  // record 为真（打扰时机、学业页的待处理里选完）：另记一条手动的同步记录，写明这次落了什么。
  Future<SyncItemResult> settle(TermRef term, List<CourseRecord> courses, ScheduleResolution resolution, {required String? expectedRevisionId, bool record = false}) async {
    if (!record) return _settle(term, courses, resolution, expectedRevisionId: expectedRevisionId);
    final before = (await gateway.readSchedule(ScheduleScope.term(term))).data;
    final settled = await _settle(term, courses, resolution, expectedRevisionId: expectedRevisionId);
    final change = _settledChange(term, before, courses, resolution, settled);
    if (change != null) await _record(SyncRecord(at: DateTime.now().toUtc(), trigger: SyncTrigger.manual, changes: [change]));
    return settled;
  }

  // 冲突落库后的变化：选了用教务的或合并就是落库前后的差别；留着等你来选的记成待处理（教务和本机的差别）；选了保留本地的不记。
  SyncChange? _settledChange(TermRef term, ScheduleView? before, List<CourseRecord> courses, ScheduleResolution resolution, SyncItemResult settled) => switch (resolution) {
    KeepLocal(remember: false) when settled.outcome == SyncOutcome.skipped => scheduleSyncChange(term, before, courses, held: true),
    TakeEdu() when settled.outcome == SyncOutcome.completed => scheduleSyncChange(term, before, courses),
    MergeEdu(:final merged) when settled.outcome == SyncOutcome.completed => scheduleSyncChange(term, before, merged),
    _ => null,
  };

  Future<SyncItemResult> _settle(TermRef term, List<CourseRecord> courses, ScheduleResolution resolution, {required String? expectedRevisionId}) async {
    final label = '课表 · ${term.label.isEmpty ? term.key : term.label}';
    switch (resolution) {
      case KeepLocal(:final remember):
        final held = await gateway.holdScheduleSync(term, courses, dismissed: remember);
        if (!held.ok || held.data == null) return _failure(label, held.error);
        return SyncItemResult(label, SyncOutcome.skipped, held.data! ? '和你改过的课表不一样，等你来选' : '保留本地自定义版本');
      case TakeEdu():
        final committed = await gateway.commitScheduleSync(term, courses, confirm: true, expectedRevisionId: expectedRevisionId);
        return committed.ok ? SyncItemResult(label, SyncOutcome.completed, '已同步，旧版本可回退') : _failure(label, committed.error);
      case MergeEdu(:final merged, :final summary):
        final committed = await gateway.commitScheduleMerge(term, courses, merged, summary, expectedRevisionId: expectedRevisionId);
        return committed.ok ? SyncItemResult(label, SyncOutcome.completed, '已合并所选改动，旧版本可回退') : _failure(label, committed.error);
    }
  }

  Future<void> _syncBells(
    TermRef current,
    List<TermRef> terms,
    List<SyncItemResult> items,
    Future<BellsChoice> Function(TermRef target, BellsView source) choose,
    bool Function() isActive,
  ) async {
    final fetched = await gateway.syncBells(current);
    if (!isActive()) return;
    if (!fetched.ok || fetched.data == null) {
      items.add(_failure('作息', fetched.error));
      return;
    }
    final adopted = await gateway.readBellsSource(current);
    if (!isActive()) return;
    if (!adopted.ok) {
      items.add(_failure('作息来源', adopted.error));
      return;
    }
    if (adopted.data != null) {
      final effective = await gateway.readBells(current);
      if (!effective.ok) {
        items.add(_failure('作息读取', effective.error));
        return;
      }
      if (effective.data?.periods.isNotEmpty == true) {
        items.add(SyncItemResult('作息', SyncOutcome.completed, '已刷新本学期原始数据；继续采用${adopted.data!.label}的作息'));
        return;
      }
    } else if (fetched.data!.periods.isNotEmpty) {
      items.add(const SyncItemResult('作息', SyncOutcome.completed, '已使用本学期作息'));
      return;
    }

    // 最新历史学期优先，其次其他已公布学期；每次只加载候选的一套小型作息表。
    final candidates = terms.where((term) => term.key != current.key).toList()
      ..sort((left, right) => right.key.compareTo(left.key));
    final ordered = [
      ...candidates.where((term) => term.key.compareTo(current.key) < 0),
      ...candidates.where((term) => term.key.compareTo(current.key) >= 0),
    ];
    // 来源失效而本学期已有数据，也经用户确认后恢复本学期，不静默改绑定。
    if (adopted.data != null && fetched.data!.periods.isNotEmpty) ordered.insert(0, current);
    for (final term in ordered) {
      if (!isActive()) return;
      GatewayResult<BellsView> candidate;
      if (term.key == current.key) {
        candidate = fetched;
      } else {
        final binding = await gateway.readBellsSource(term);
        if (!isActive()) return;
        if (!binding.ok) {
          items.add(_failure('作息 · ${term.label}', binding.error));
          continue;
        }
        candidate = await gateway.readBells(term);
        if (!isActive()) return;
        // 只能采用某学期原始缓存，不把间接引用误标为它的原始作息。
        if (!candidate.ok) {
          items.add(_failure('作息 · ${term.label}', candidate.error));
          continue;
        }
        if (binding.data != null || candidate.data?.periods.isNotEmpty != true) {
          candidate = await gateway.syncBells(term);
        }
      }
      if (!candidate.ok || candidate.data == null) {
        items.add(_failure('作息 · ${term.label}', candidate.error));
        if (_stopCodes.contains(candidate.error?.code)) return;
        continue;
      }
      if (candidate.data!.periods.isEmpty) continue;
      if (!isActive()) return;
      final choice = await choose(current, candidate.data!);
      if (!isActive()) return;
      if (choice == BellsChoice.cancel) {
        items.add(const SyncItemResult('作息采用', SyncOutcome.skipped, '未更改作息来源'));
        return;
      }
      if (choice == BellsChoice.next) continue;
      final saved = await gateway.useBellsSource(current, term);
      items.add(saved.ok
          ? SyncItemResult('作息采用', SyncOutcome.completed, '已保存：采用${term.label}的作息')
          : _failure('作息采用', saved.error));
      return;
    }
    if (isActive()) items.add(const SyncItemResult('作息采用', SyncOutcome.skipped, '尚未采用可用作息，保留节次显示'));
  }

  SyncItemResult _failure(String label, GatewayError? error) {
    return SyncItemResult(label, SyncOutcome.failed, error?.message ?? '未获得有效结果', code: error?.code);
  }
}

// 课表这一学期的变化：同步前（before，本机还没有这学期时为空，记成第一次）与之后（after）比，没有差别时为空。
ScheduleSyncChange? scheduleSyncChange(TermRef term, ScheduleView? before, List<CourseRecord> after, {bool held = false}) {
  final first = before?.revisionId == null;
  final diff = first ? const <CourseChange>[] : scheduleChanges(before!.courses, after);
  if (!first && diff.isEmpty) return null;
  List<String> names(String kind, String Function(CourseChange change) name) => [for (final change in diff) if (change.kind == kind) name(change)];
  final added = names('新增', (change) => change.after!.courseName), removed = names('删除', (change) => change.before!.courseName);
  final changed = names('修改', (change) => '${change.after!.courseName}：${change.fields.join('、')}');
  return ScheduleSyncChange(
    termKey: term.key,
    termLabel: term.label,
    added: added.take(syncRecordNames).toList(),
    removed: removed.take(syncRecordNames).toList(),
    changed: changed.take(syncRecordNames).toList(),
    counts: first ? (after.length, 0, 0) : (added.length, removed.length, changed.length),
    first: first,
    held: held,
    before: first || held ? null : before!.revisionId,
  );
}

// 成绩这一学期的变化：按课程代码加课名比，新出的与分数变了的；本机原来没有这学期的成绩时记成第一次；没有差别时为空。
GradeSyncChange? gradeSyncChange(TermRef term, GradesView? before, GradesView after) {
  String key(GradeCourse course) => '${course.courseCode}\u0000${course.courseName}';
  String line(GradeCourse course) => [course.courseName, if (course.score != null) '${course.score}'].join(' ');
  final first = before == null;
  final old = {for (final course in before?.effective ?? const <GradeCourse>[]) key(course): course};
  final added = [for (final course in after.effective) if (!old.containsKey(key(course))) line(course)];
  final changed = [for (final course in after.effective) if (old[key(course)] case final previous? when '${previous.score}' != '${course.score}') line(course)];
  if (!first && added.isEmpty && changed.isEmpty) return null;
  if (first && after.effective.isEmpty) return null;
  return GradeSyncChange(termKey: term.key, termLabel: term.label, added: added.take(syncRecordNames).toList(), changed: changed.take(syncRecordNames).toList(), counts: (added.length, changed.length), first: first);
}
