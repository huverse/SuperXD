import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/gateway_code.dart';
import 'package:superxd/domain/schedule_store.dart';

// 自动同步的编排（人工决策见 domain/auto_sync.dart）：设备级，经账号门面跟着当前账号走。
// 决定什么时候同步（到期、没有别的同步在跑）、同步什么（设置里的学年与内容）、冲突怎么办（不覆盖，教务确有新改动的留到打扰时机问），
// 并按设置排好或撤掉系统的后台任务。真正的请求与落库都经 CampusSync 与 CampusGateway。
class AutoSync extends ChangeNotifier {
  AutoSync({required this.gateway, this.scheduler, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final CampusGateway gateway;
  // 系统后台任务；测试与后台任务自己那份为空。
  final BackgroundSyncScheduler? scheduler;
  final DateTime Function() _clock;
  late final _sync = CampusSync(gateway);
  Future<void>? _running;

  // 当前账号的设置与上次结果（设置页显示）；没登录时为空。
  AutoSyncView? view;
  // 等用户来选的教务课表（打扰时机里一份一份地问）。
  List<HeldScheduleSync> held = const [];

  // 恢复会话、切换账号或退出后调：读设置排好或撤掉后台任务，读等着选的课表。
  // relogin 是刚登录过（会话是新的）：把「登录过期、已暂停」清掉，自动同步接着跑；冷启动只是读回本机会话，并不知道它还有效，不清。
  Future<void> accountChanged({required bool signedIn, bool relogin = false}) async {
    if (!signedIn) {
      view = null;
      held = const [];
      notifyListeners();
      await _cancel();
      return;
    }
    final read = await gateway.readAutoSync();
    if (!read.ok || read.data == null) return;
    var current = read.data!;
    if (relogin && current.status.state == AutoSyncState.paused) {
      final status = AutoSyncStatus(lastAttemptAt: current.status.lastAttemptAt, lastSuccessAt: current.status.lastSuccessAt);
      if ((await gateway.recordAutoSync(status)).ok) current = AutoSyncView(setting: current.setting, status: status);
    }
    view = current;
    await _reloadHeld();
    await _apply(current);
  }

  // 存设置：存好才换后台任务，返回失败原因（成功为空）。
  Future<String?> save(AutoSyncSetting setting) async {
    final saved = await gateway.saveAutoSyncSetting(setting);
    if (!saved.ok) return saved.error?.message ?? '设置没有保存，请重试';
    final current = view = AutoSyncView(setting: setting, status: view?.status ?? const AutoSyncStatus());
    notifyListeners();
    await _apply(current);
    return null;
  }

  // 到期就同步一轮（后台任务与回到前台都调它，foreground 表示用户正打开着应用）；同一时刻只跑一轮，有别的同步在跑就这次不跑。
  Future<void> runIfDue({bool foreground = false}) => _running ??= _runIfDue(foreground).whenComplete(() => _running = null);

  Future<void> _runIfDue(bool foreground) async {
    final read = await gateway.readAutoSync();
    if (!read.ok || read.data == null) return;
    final current = read.data!, now = _clock();
    if (!autoSyncDue(current, now, foreground: foreground) || CampusSync.activeRuns > 0) return;
    final years = current.setting.years ?? await _currentYear();
    final previous = current.status;
    if (years == null) {
      await _record(AutoSyncStatus(lastAttemptAt: now, lastSuccessAt: previous.lastSuccessAt, state: AutoSyncState.failed, message: '还没有学期，先在今天页手动同步一次'), current);
      return;
    }
    campusLog('[AutoSync] action=start years=${years.length} contents=${current.setting.contents.map((content) => content.name).join(',')}');
    // 先记下这次尝试，中途被系统停掉也不会马上又来一轮。
    await _record(AutoSyncStatus(lastAttemptAt: now, lastSuccessAt: previous.lastSuccessAt, state: previous.state, message: previous.message), current);
    // 登录过期时不打断：不丢本机会话（见 keepSessionDuring），只记暂停。
    final report = await gateway.keepSessionDuring(() => _sync.run(
      contents: current.setting.contents,
      years: years,
      // 有人手动同步了就让路（下一个检查点停下），不和它抢同一个教务会话。
      isActive: () => CampusSync.activeRuns == 1,
      // 冲突时不覆盖：教务这份和上次同步的一样（只是你自己改过）就悄悄保留本地、以后也不问；教务确有新改动才留到打扰时机问。
      resolveSchedule: (term, plan, courses) async => KeepLocal(remember: plan.base != null && fingerprint(plan.base!) == fingerprint(courses)),
      // 采用别的学期的作息必须本人确认，自动同步不改作息来源。
      chooseBells: (_, _) async => BellsChoice.cancel,
    ));
    final status = _statusOf(report, now, previous);
    campusLog('[AutoSync] action=finish state=${status.state?.name} items=${report.items.length} unfinished=${report.unfinished.length}');
    await _record(status, current);
    await _reloadHeld();
  }

  // 打扰时机里处理暂存的那份：按选择落库，再重读等着选的课表。
  Future<SyncItemResult> settle(HeldScheduleSync held, ScheduleResolution resolution, {required String? expectedRevisionId}) async {
    final result = await _sync.settle(held.term, held.courses, resolution, expectedRevisionId: expectedRevisionId);
    await _reloadHeld();
    return result;
  }

  Future<Set<String>?> _currentYear() async {
    final terms = await gateway.listTerms();
    final year = terms.data?.firstOrNull?.xn;
    return year == null ? null : {year};
  }

  AutoSyncStatus _statusOf(CampusSyncReport report, DateTime started, AutoSyncStatus previous) {
    AutoSyncStatus failed(AutoSyncState state, String message) => AutoSyncStatus(lastAttemptAt: started, lastSuccessAt: previous.lastSuccessAt, state: state, message: message);
    if (report.sessionExpired) return failed(AutoSyncState.paused, '登录已过期，自动同步已暂停，重新登录后继续');
    if (report.rateLimited) return failed(AutoSyncState.limited, '教务提示请求太频繁，到下次再同步');
    final failures = report.items.where((item) => item.outcome == SyncOutcome.failed).toList();
    if (failures.isNotEmpty && failures.every((item) => item.code == GatewayCode.networkFailed || item.code == GatewayCode.networkTimeout)) {
      return failed(AutoSyncState.network, '没连上教务，联网后再试');
    }
    if (failures.isNotEmpty) return failed(AutoSyncState.failed, '${failures.first.label}：${failures.first.message}');
    return AutoSyncStatus(lastAttemptAt: started, lastSuccessAt: started, state: AutoSyncState.ok);
  }

  Future<void> _record(AutoSyncStatus status, AutoSyncView current) async {
    final recorded = await gateway.recordAutoSync(status);
    if (!recorded.ok) {
      campusLog('[AutoSync] action=record errorType=${recorded.error?.code}');
      return;
    }
    // 设置以 view 里的为准：这轮同步期间用户可能改过。
    view = AutoSyncView(setting: view?.setting ?? current.setting, status: status);
    notifyListeners();
  }

  Future<void> _reloadHeld() async {
    final read = await gateway.readHeldScheduleSyncs();
    if (!read.ok || read.data == null) return;
    held = read.data!;
    notifyListeners();
  }

  // 开着就按间隔排、第一次排在下次到期的时候，关着就撤掉。系统接口出错只记日志，设置照样存着。
  Future<void> _apply(AutoSyncView current) async {
    try {
      current.setting.enabled ? await scheduler?.schedule(current.setting.interval, delay: autoSyncDelay(current, _clock())) : await scheduler?.cancel();
    } catch (error, stack) {
      campusLog('[AutoSync] action=schedule errorType=${error.runtimeType}\n$stack');
    }
  }

  Future<void> _cancel() async {
    try {
      await scheduler?.cancel();
    } catch (error, stack) {
      campusLog('[AutoSync] action=cancel errorType=${error.runtimeType}\n$stack');
    }
  }
}
