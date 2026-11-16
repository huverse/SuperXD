import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// 本应用的系统通知共用一份初始化：插件在一个进程里只认最后一次 initialize 的点按回调，课前提醒与同步结果各初始化一次会互相盖掉。
// 点了带 payload 的通知（应用开着或在后台）进 campusNotificationTaps；冷启动由通知拉起时组合根经 campusNotificationLaunch 取一次。
// iOS 启动时不弹通知权限（权限只在用户打开提醒或自动同步时申请）。
final campusNotificationTaps = StreamController<String>.broadcast();
Future<void>? _ready;

Future<void> initializeCampusNotifications(FlutterLocalNotificationsPlugin plugin) => _ready ??= plugin.initialize(
  settings: const InitializationSettings(
    android: AndroidInitializationSettings('ic_stat_reminder'),
    iOS: DarwinInitializationSettings(requestAlertPermission: false, requestSoundPermission: false, requestBadgePermission: false),
  ),
  onDidReceiveNotificationResponse: (response) {
    if (response.payload case final payload? when payload.isNotEmpty) campusNotificationTaps.add(payload);
  },
);

// 这次冷启动是不是点通知拉起的：是就返回那条通知的 payload。
Future<String?> campusNotificationLaunch([FlutterLocalNotificationsPlugin? given]) async {
  final plugin = given ?? FlutterLocalNotificationsPlugin();
  await initializeCampusNotifications(plugin);
  final details = await plugin.getNotificationAppLaunchDetails();
  return details?.didNotificationLaunchApp == true ? details!.notificationResponse?.payload : null;
}
