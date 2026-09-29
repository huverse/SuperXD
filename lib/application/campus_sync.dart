import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/gateway_code.dart';

enum SyncContent { schedule, bells, grades }

class SyncSelection {
  SyncSelection({required Set<String> years, required Set<SyncContent> contents})
      : years = Set.unmodifiable(years), contents = Set.unmodifiable(contents);
  final Set<String> years;
  final Set<SyncContent> contents;
  bool get valid => years.isNotEmpty && contents.isNotEmpty;
}
enum SyncOutcome { completed, skipped, failed }
enum BellsChoice { use, next, cancel }

class SyncItemResult {
  const SyncItemResult(this.label, this.outcome, this.message, {this.code});
  final String label;
  final SyncOutcome outcome;
  final String message;
  final String? code;
}

class CampusSyncReport {
  const CampusSyncReport(this.items, {this.busy = false, this.cancelled = false, this.unfinished = const []});
  final List<SyncItemResult> items;
  final bool busy;
  final bool cancelled;
  // 提前结束时尚未处理的同步项，按原执行顺序排列。
  final List<String> unfinished;
  bool get sessionExpired => items.any((item) => item.code == GatewayCode.sessionExpired);
}

class CampusSyncProgress {
  const CampusSyncProgress(this.label, {this.waitingForInput = false});
  final String label;
  final bool waitingForInput;
}

class CampusSync {
  CampusSync(this.gateway);
  final CampusGateway gateway;
  bool _running = false;

  // [人工决策-2026-09-24 21:39:35] 用户先多选学年与同步项，三类数据统一范围；跨学年作息来源仍须明确确认。
  Future<CampusSyncReport> run({
    required Set<SyncContent> contents,
    Set<String>? years,
    required Future<bool> Function(TermRef term, String message) confirmSchedule,
    required Future<BellsChoice> Function(TermRef target, BellsView source) chooseBells,
    required bool Function() isActive,
    void Function(CampusSyncProgress progress)? onProgress,
  }) async {
    if (_running) return const CampusSyncReport([], busy: true);
    if (contents.isEmpty || years?.isEmpty == true) return const CampusSyncReport([]);
    _running = true;
    final items = <SyncItemResult>[];
    try {
      // 显式同步才刷新学期，防止本地列表过期导致漏同步新学期。
      // [人工决策-2026-09-25 14:45:43] 进度只报告已有任务阶段，不改同步范围、顺序和确认规则，不生成假百分比。
      onProgress?.call(const CampusSyncProgress('正在刷新学期列表'));
      final listed = await gateway.syncTerms();
      if (!isActive()) return CampusSyncReport(items, cancelled: true, unfinished: const ['所选学年的全部内容']);
      if (!listed.ok || listed.data == null) {
        items.add(_failure('学期列表', listed.error));
        return CampusSyncReport(items, cancelled: !isActive());
      }
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
              final confirmed = await confirmSchedule(term, plan.data!.message ?? syncOverwriteMessage);
              onProgress?.call(CampusSyncProgress('正在保存$label'));
              if (!isActive()) return stop(true);
              if (!confirmed) {
                items.add(SyncItemResult(label, SyncOutcome.skipped, '保留本地自定义版本'));
              } else {
                final committed = await gateway.commitScheduleSync(term, fetched.data!.courses, confirm: true, expectedRevisionId: plan.data!.revisionId);
                items.add(committed.ok
                    ? SyncItemResult(label, SyncOutcome.completed, '已同步，旧版本可回退')
                    : _failure(label, committed.error));
              }
            } else {
              // [人工决策-2026-09-25 00:19:22] 沿用学年/数据项选择；再次提交在事务内核对实时head，未提交不得报已同步。
              final committed = await gateway.commitScheduleSync(term, fetched.data!.courses, confirm: false);
              items.add(committed.ok
                  ? SyncItemResult(label, SyncOutcome.completed, fetched.data!.courses.isEmpty ? '教务暂无课程，已保存空课表' : '已同步')
                  : _failure(label, committed.error));
            }
          }
          pending.removeAt(0);
          if (items.last.code == GatewayCode.sessionExpired) return stop(!isActive());
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
          if (items.any((item) => item.code == GatewayCode.sessionExpired)) return stop(!isActive());
        }
        if (!isActive()) return stop(true);
        if (contents.contains(SyncContent.grades)) {
          onProgress?.call(CampusSyncProgress('正在同步成绩 · ${term.label}'));
          final grades = await gateway.syncGrades(term);
          items.add(grades.ok && grades.data != null
              ? SyncItemResult('成绩 · ${term.label}', SyncOutcome.completed, grades.data!.empty ? '教务暂无成绩，已保存空结果' : '已同步')
              : _failure('成绩 · ${term.label}', grades.error));
          pending.removeAt(0);
          if (grades.error?.code == GatewayCode.sessionExpired) return stop(!isActive());
        }
      }
      return CampusSyncReport(items, cancelled: !isActive());
    } finally {
      _running = false;
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
        if (candidate.error?.code == GatewayCode.sessionExpired) return;
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
