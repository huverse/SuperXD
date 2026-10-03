import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/course_occurrence.dart';

// 只安排未来 14 天、最多 128 条，每次对账整体替换，系统闹钟数有界。
const reminderWindowDays = 14;
const reminderLimit = 128;

class PlannedReminder {
  const PlannedReminder({required this.fireAt, required this.title, required this.body, required this.occurrence});
  final DateTime fireAt;
  final String title;
  final String body;
  final CourseOccurrence occurrence;
}

// 提醒时刻已过的不安排；按时间先后取前 reminderLimit 条。
List<PlannedReminder> planReminders(List<CourseOccurrence> occurrences, {required int leadMinutes, required DateTime now}) {
  final planned = <PlannedReminder>[];
  for (final occurrence in occurrences) {
    final fireAt = occurrence.start.subtract(Duration(minutes: leadMinutes));
    if (!fireAt.isAfter(now)) continue;
    final start = campusInstant(occurrence.start);
    final clock = '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
    final meeting = occurrence.meeting;
    final periods = meeting.periodStart == meeting.periodEnd ? '第${meeting.periodStart}节' : '第${meeting.periodStart}–${meeting.periodEnd}节';
    planned.add(PlannedReminder(
      fireAt: fireAt,
      title: occurrence.course.courseName,
      body: [clock, periods, if (meeting.place.isNotEmpty) meeting.place].join(' · '),
      occurrence: occurrence,
    ));
    if (planned.length == reminderLimit) break;
  }
  return planned;
}

class ReminderCapability {
  const ReminderCapability({required this.notifications, required this.exact});
  // 系统是否允许本应用发通知。
  final bool notifications;
  // 是否允许精确闹钟；不允许时提醒可能延迟几分钟。
  final bool exact;
}

// 课前提醒的系统调度端口，由 device 层实现，编排在 application/campus_reminders.dart。
abstract class CourseReminderPort {
  Future<ReminderCapability> capability();
  // 申请通知权限，返回是否已允许。
  Future<bool> requestNotifications();
  // 打开系统“闹钟和提醒”设置页，由用户决定是否允许准时提醒。
  Future<void> requestExact();
  // 用 reminders 整体替换本应用已安排的课前提醒，不影响下载等其他通知。
  Future<void> replace(List<PlannedReminder> reminders, {required bool exact});
}
