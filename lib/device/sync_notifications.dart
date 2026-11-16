import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:superxd/device/campus_notifications.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/sync_record.dart';

// 自动同步发现变化时的系统通知（实现 domain 的 SyncNotices，人工决策见 domain/sync_record.dart）：单独一个通知渠道「同步结果」，
// 固定一个编号，新的盖掉旧的、不堆一串；点开进学业页的同步记录（payload syncRecordsPayload，组合根接）。
// 没有通知权限时什么也不做（权限在打开自动同步时申请）；后台同步那份引擎里也能发（插件在后台引擎里同样注册）。
const syncRecordsPayload = 'sync_records';

class SyncNotifications implements SyncNotices {
  SyncNotifications([FlutterLocalNotificationsPlugin? plugin]) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;
  // 课前提醒用 610000 起的一段，这里另取一个。
  static const _id = 620000;
  static const _details = NotificationDetails(
    android: AndroidNotificationDetails('sync_result', '同步结果', channelDescription: '自动同步发现课表、成绩有变化时提醒', icon: 'ic_stat_reminder'),
    iOS: DarwinNotificationDetails(),
  );

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  IOSFlutterLocalNotificationsPlugin? get _ios => _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();

  @override
  Future<void> show(SyncRecord record) async {
    final notice = syncRecordNotice(record);
    if (notice == null) return;
    await initializeCampusNotifications(_plugin);
    final allowed = switch ((_android, _ios)) {
      (final android?, _) => await android.areNotificationsEnabled() ?? false,
      (_, final ios?) => (await ios.checkPermissions())?.isEnabled ?? false,
      _ => false,
    };
    if (!allowed) {
      campusLog('[SyncNotices] action=show skipped=permission');
      return;
    }
    await _plugin.show(id: _id, title: notice.title, body: notice.body, notificationDetails: _details, payload: syncRecordsPayload);
    campusLog('[SyncNotices] action=show changes=${record.changes.length}');
  }

  // 打开自动同步时顺带申请通知权限（同课前提醒，只在用户打开时问）；给了返回真。
  @override
  Future<bool> request() async {
    await initializeCampusNotifications(_plugin);
    return await (_android?.requestNotificationsPermission() ?? _ios?.requestPermissions(alert: true, sound: true)) ?? false;
  }
}
