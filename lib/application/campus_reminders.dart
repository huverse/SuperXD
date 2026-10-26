import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/course_reminder.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';

// 一次对账的结果，供提醒设置界面如实显示：开没开、排了几条排到哪天、缺什么、是否准时。
class ReminderStatus {
  const ReminderStatus({
    required this.term,
    required this.setting,
    required this.capability,
    this.scheduled = 0,
    this.lastDate,
    this.gap,
  });
  final TermRef? term;
  final ReminderSetting setting;
  final ReminderCapability capability;
  final int scheduled;
  final String? lastDate;
  final OccurrenceGap? gap;
}

// 课前提醒编排：读本机的当前学期、提醒设置、课表与作息，展开未来 14 天的课程实例，整体替换系统里的提醒。
// 只读本地数据，从不联网；串行执行，规划结果与上次相同时不重复替换。
// 没有当前学期、未开启或没有通知权限时撤销本应用的全部课前提醒。
// 开了状态栏胶囊且系统有实时更新（Android 16 起）时，提醒改发成实时更新；系统没有时照常是普通提醒。
// [人工决策-2026-10-18 22:44:41] 适配 OPPO 流体云（用户四项都选推荐）：走 Android 16 原生实时更新，不接厂商 SDK；
// 并入课前提醒（同一条通知、提前量沿用、先开提醒才能开胶囊），开课前 N 分钟到下课显示，课间不挂；胶囊上是系统倒计时，课名教室在展开的通知里。
class CampusReminders {
  CampusReminders({required this.gateway, required this.port, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final CampusGateway gateway;
  final CourseReminderPort port;
  final DateTime Function() _clock;
  final _lock = Lock();
  String? _applied;

  Future<ReminderStatus> reconcile() => _lock.synchronized(() async {
    final capability = await port.capability();
    final terms = await gateway.listTerms();
    final term = terms.ok ? terms.data?.firstOrNull : null;
    if (term == null) {
      await _apply(const [], capability);
      return ReminderStatus(term: null, setting: ReminderSetting.initial, capability: capability);
    }
    final setting = (await gateway.readReminderSetting(term)).data ?? ReminderSetting.initial;
    if (!setting.enabled || !capability.notifications) {
      await _apply(const [], capability);
      return ReminderStatus(term: term, setting: setting, capability: capability);
    }
    final schedule = await gateway.readSchedule(ScheduleScope.term(term));
    final bells = await gateway.readBells(term);
    final now = _clock().toUtc();
    final today = formatCampusDate(campusInstant(now));
    final occurrences = courseOccurrences(
      courses: schedule.data?.courses ?? const [],
      termStartDate: schedule.data?.termStartDate,
      bells: bells.data?.periods ?? const [],
      from: today,
      to: formatIsoDate(parseIsoDate(today).add(const Duration(days: reminderWindowDays - 1))),
    );
    final live = setting.live && capability.live;
    final planned = planReminders(occurrences.items, leadMinutes: setting.leadMinutes, now: now, live: live, limit: capability.limit);
    await _apply(planned, capability, live: live);
    return ReminderStatus(
      term: term,
      setting: setting,
      capability: capability,
      scheduled: planned.length,
      lastDate: planned.lastOrNull?.occurrence.date,
      gap: occurrences.gap,
    );
  });

  Future<void> _apply(List<PlannedReminder> planned, ReminderCapability capability, {bool live = false}) async {
    final signature = [
      capability.exact,
      live,
      for (final reminder in planned) '${reminder.fireAt.toIso8601String()}|${reminder.occurrence.end.toIso8601String()}|${reminder.title}|${reminder.body}',
    ].join('\n');
    if (signature == _applied) return;
    await port.replace(planned, exact: capability.exact, live: live);
    _applied = signature;
  }
}
