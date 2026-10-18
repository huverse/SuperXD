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

// 提醒时刻已过的不安排；发成实时更新时（live）留到下课，期间重新对账不会撤掉正在显示的那条。按时间先后取前 reminderLimit 条。
List<PlannedReminder> planReminders(List<CourseOccurrence> occurrences, {required int leadMinutes, required DateTime now, bool live = false}) {
  final planned = <PlannedReminder>[];
  for (final occurrence in occurrences) {
    final fireAt = occurrence.start.subtract(Duration(minutes: leadMinutes));
    if (!(live ? occurrence.end : fireAt).isAfter(now)) continue;
    final place = occurrence.meeting.place;
    planned.add(PlannedReminder(
      fireAt: fireAt,
      title: occurrence.course.courseName,
      body: [formatCampusClock(occurrence.start), occurrence.periods, if (place.isNotEmpty) place].join(' · '),
      occurrence: occurrence,
    ));
    if (planned.length == reminderLimit) break;
  }
  return planned;
}

class ReminderCapability {
  const ReminderCapability({required this.notifications, required this.exact, this.live = false, this.liveAllowed = false});
  // 系统是否允许本应用发通知。
  final bool notifications;
  // 是否允许精确闹钟；不允许时提醒可能延迟几分钟。
  final bool exact;
  // 系统有没有实时更新（Android 16 起；OPPO 流体云按同一接口显示）。
  final bool live;
  // 用户是否在系统设置里允许本应用的实时更新；不允许时照常发，只显示为普通通知。
  final bool liveAllowed;
}

// 课前提醒的系统调度端口，由 device 层实现，编排在 application/campus_reminders.dart。
abstract class CourseReminderPort {
  Future<ReminderCapability> capability();
  // 申请通知权限，返回是否已允许。
  Future<bool> requestNotifications();
  // 打开系统“闹钟和提醒”设置页，由用户决定是否允许准时提醒。
  Future<void> requestExact();
  // 打开系统里本应用的实时更新设置页。
  Future<void> requestLive();
  // 用 reminders 整体替换本应用已安排的课前提醒，不影响下载等其他通知。
  // live 为真时每条提醒发成实时更新：开课前倒数到开课，上课中倒数到下课，下课自动消失。
  Future<void> replace(List<PlannedReminder> reminders, {required bool exact, required bool live});
}
