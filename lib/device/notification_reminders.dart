import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/course_reminder.dart';

// 课前提醒的系统实现：flutter_local_notifications 定时通知，开机后由插件的接收器重新排定。
// 只管理自己 id 段内的提醒，不调用 cancelAll，避免撤掉下载进度等其他通知。
// 开了状态栏胶囊时改由原生侧 CourseLive.kt 发实时更新（插件不支持），两条路同一时刻只走一条。
class NotificationReminders implements CourseReminderPort {
  NotificationReminders({FlutterLocalNotificationsPlugin? plugin}) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;
  static const _live = MethodChannel('superxd/course_live');
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
  // iOS 每个应用最多挂 64 条待发的本地通知，多排的系统直接丢掉（安排时就按 capability 的 limit 只排这么多）。
  static const _iosPendingLimit = 64;
  Future<void>? _ready;

  // iOS 启动时不弹通知权限（权限只在用户打开提醒时申请）。
  Future<void> _initialize() => _ready ??= _plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_reminder'),
      iOS: DarwinInitializationSettings(requestAlertPermission: false, requestSoundPermission: false, requestBadgePermission: false),
    ),
  );

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  IOSFlutterLocalNotificationsPlugin? get _ios => _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();

  @override
  Future<ReminderCapability> capability() async {
    await _initialize();
    final android = _android, ios = _ios;
    if (android == null && ios == null) return const ReminderCapability(notifications: false, exact: false);
    final live = (await _live.invokeMapMethod<String, bool>('capability'))!;
    return ReminderCapability(
      // iOS 的本地通知本来就准时，没有精确闹钟权限这一说。
      notifications: android != null ? await android.areNotificationsEnabled() ?? false : (await ios!.checkPermissions())?.isEnabled ?? false,
      exact: android != null ? await android.canScheduleExactNotifications() ?? false : true,
      live: live['live']!,
      liveAllowed: live['allowed']!,
      limit: ios != null ? _iosPendingLimit : reminderLimit,
    );
  }

  @override
  Future<bool> requestNotifications() async {
    await _initialize();
    return await (_android?.requestNotificationsPermission() ?? _ios?.requestPermissions(alert: true, sound: true)) ?? false;
  }

  @override
  Future<void> requestExact() async {
    await _initialize();
    await _android?.requestExactAlarmsPermission();
  }

  @override
  Future<void> requestLive() => _live.invokeMethod<void>('openSettings');

  @override
  Future<void> replace(List<PlannedReminder> reminders, {required bool exact, required bool live}) async {
    await _initialize();
    for (final pending in await _plugin.pendingNotificationRequests()) {
      if (pending.id >= _idBase && pending.id < _idBase + reminderLimit) await _plugin.cancel(id: pending.id);
    }
    // 钟点在这里按校园时区写好，原生侧不算时区；上课中的正文换成下课时刻，人已在教室也留着地点方便核对。
    await _live.invokeMethod<void>('replace', {
      'items': jsonEncode([
        if (live)
          for (final reminder in reminders.take(reminderLimit))
            {
              'key': reminder.occurrence.key,
              'fireAt': reminder.fireAt.millisecondsSinceEpoch,
              'start': reminder.occurrence.start.millisecondsSinceEpoch,
              'end': reminder.occurrence.end.millisecondsSinceEpoch,
              'title': reminder.title,
              'before': reminder.body,
              'during': ['上课中 · 至${formatCampusClock(reminder.occurrence.end)}', if (reminder.occurrence.meeting.place.isNotEmpty) reminder.occurrence.meeting.place].join(' · '),
            },
      ]),
    });
    // iOS 的实时活动只在打开应用时出现（[人工决策] 见 ios/Runner/CourseBridge.swift），开着胶囊也照常发课前通知；已过提醒时刻、还没下课的那节只进实时活动。
    if (live && _ios == null) return;
    final campus = tz.getLocation(campusTimeZone);
    final now = DateTime.now();
    for (final (index, reminder) in reminders.where((reminder) => reminder.fireAt.isAfter(now)).take(reminderLimit).indexed) {
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
