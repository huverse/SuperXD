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
    final planned = planReminders(occurrences.items, leadMinutes: setting.leadMinutes, now: now);
    await _apply(planned, capability);
    return ReminderStatus(
      term: term,
      setting: setting,
      capability: capability,
      scheduled: planned.length,
      lastDate: planned.lastOrNull?.occurrence.date,
      gap: occurrences.gap,
    );
  });

  Future<void> _apply(List<PlannedReminder> planned, ReminderCapability capability) async {
    final signature = [capability.exact, for (final reminder in planned) '${reminder.fireAt.toIso8601String()}|${reminder.title}|${reminder.body}'].join('\n');
    if (signature == _applied) return;
    await port.replace(planned, exact: capability.exact);
    _applied = signature;
  }
}
