import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/course_reminder.dart';

// 课前提醒的系统实现：flutter_local_notifications 定时通知，开机后由插件的接收器重新排定。
// 只管理自己 id 段内的提醒，不调用 cancelAll，避免撤掉下载进度等其他通知。
class NotificationReminders implements CourseReminderPort {
  NotificationReminders({FlutterLocalNotificationsPlugin? plugin}) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;
  static const _idBase = 610000;
  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'course_reminder',
      '课前提醒',
      channelDescription: '上课前按设置的提前时间提醒',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      icon: 'ic_stat_reminder',
    ),
  );
  Future<void>? _ready;

  Future<void> _initialize() => _ready ??= _plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_reminder')));

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  @override
  Future<ReminderCapability> capability() async {
    await _initialize();
    final android = _android;
    if (android == null) return const ReminderCapability(notifications: false, exact: false);
    return ReminderCapability(
      notifications: await android.areNotificationsEnabled() ?? false,
      exact: await android.canScheduleExactNotifications() ?? false,
    );
  }

  @override
  Future<bool> requestNotifications() async {
    await _initialize();
    return await _android?.requestNotificationsPermission() ?? false;
  }

  @override
  Future<void> requestExact() async {
    await _initialize();
    await _android?.requestExactAlarmsPermission();
  }

  @override
  Future<void> replace(List<PlannedReminder> reminders, {required bool exact}) async {
    await _initialize();
    for (final pending in await _plugin.pendingNotificationRequests()) {
      if (pending.id >= _idBase && pending.id < _idBase + reminderLimit) await _plugin.cancel(id: pending.id);
    }
    final campus = tz.getLocation(campusTimeZone);
    for (final (index, reminder) in reminders.take(reminderLimit).indexed) {
      await _plugin.zonedSchedule(
        id: _idBase + index,
        title: reminder.title,
        body: reminder.body,
        scheduledDate: tz.TZDateTime.from(reminder.fireAt, campus),
        notificationDetails: _details,
        androidScheduleMode: exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }
}
