# device 设备能力

定位：系统能力的适配器，只实现 domain 里定义的端口，只依赖 domain 和本目录。由组合根 main.dart 创建并注入编排层，页面不直接依赖本层。

# 文件职责

- notification_reminders.dart：NotificationReminders 实现课前提醒端口 CourseReminderPort。
  - 用 flutter_local_notifications 按校园时区定时通知；开机后由插件的接收器重新排定（清单里的 ScheduledNotificationBootReceiver）。
  - 只管理自己 id 段内的提醒（最多 reminderLimit 条），不调用 cancelAll，避免撤掉下载进度等其他通知。
  - 有精确闹钟权限时准时调度，没有时改用可能延迟的普通调度；通知渠道 course_reminder，状态栏图标 ic_stat_reminder。
- home_widget_publisher.dart：HomeWidgetPublisher 实现桌面小组件端口 CourseWidgetPort。
  - 经通道 superxd/course_widget 把快照与配色（JSON）交给原生侧 CourseWidgets.kt，存进私有的 superxd_course_widget 偏好（已排除系统备份）。
  - 钟点、日期在这里按校园时区算好；原生侧只用快照带的 campusTimeZone 判断“今天”，按系统时间挑当前与下一节。
  - 原生侧在上下课时刻与校园日界用非精确闹钟（不需要权限，系统可能推迟最多约 10 分钟）刷新；改系统时间或时区时也重画；桌面上没有小组件时撤销闹钟。
  - 没用 home_widget 插件：它强制引入 Glance 与 Compose 运行时，而这里只需保存快照与刷新 RemoteViews。

# 关键规则

- 本层不做业务判断：要安排哪些提醒、小组件显示哪些课由 application 下的 campus_reminders.dart、campus_widgets.dart 决定，本层只负责整体替换。
- 权限只在用户操作时申请（打开提醒、点“开启通知”或“准时提醒”），启动时不弹权限。
