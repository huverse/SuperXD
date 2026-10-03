# device 设备能力

定位：系统能力的适配器，只实现 domain 里定义的端口，只依赖 domain 和本目录。由组合根 main.dart 创建并注入编排层，页面不直接依赖本层。

# 文件职责

- notification_reminders.dart：NotificationReminders 实现课前提醒端口 CourseReminderPort。
  - 用 flutter_local_notifications 按校园时区定时通知；开机后由插件的接收器重新排定（清单里的 ScheduledNotificationBootReceiver）。
  - 只管理自己 id 段内的提醒（最多 reminderLimit 条），不调用 cancelAll，避免撤掉下载进度等其他通知。
  - 有精确闹钟权限时准时调度，没有时改用可能延迟的普通调度；通知渠道 course_reminder，状态栏图标 ic_stat_reminder。

# 关键规则

- 本层不做业务判断：要安排哪些提醒由 application/campus_reminders.dart 决定，本层只负责整体替换。
- 权限只在用户操作时申请（打开提醒、点“开启通知”或“准时提醒”），启动时不弹权限。
