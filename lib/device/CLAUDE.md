# device 设备能力

定位：系统能力与外部服务的适配器，只实现 domain 里定义的端口，只依赖 domain 和本目录。由组合根 main.dart 创建并注入编排层，页面不直接依赖本层。

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

- 应用内更新的三个适配器，由 application/app_updates.dart 编排：
  - relay_release_feed.dart：RelayReleaseFeed 实现 AppReleaseFeed，GET 自建中转的 /v1/app/releases/<渠道>?abi=（免签名），单次 15 秒超时、响应上限 64KB、不重试；RELEASE_NOT_FOUND 当这个渠道还没有发布。parseAppRelease 把清单当外部输入逐项校验，安装包地址只认本服务的下载路径。appAbiName 把正在运行的架构映射成安装包架构名。
  - app_package_files.dart：CacheAppPackageFiles 实现 AppPackageFiles。安装包放在缓存的 app_update 文件夹（原生 FileProvider 只开放这里），只留一个版本；background_downloader 的独立命名空间 superxd_update 下载（回调与百宝箱的下载互不相干），有通知权限时以前台任务跑并在通知栏显示进度（规则同百宝箱 background_transfer.dart）；SHA-256 在后台 isolate 里算；prune 删掉版本号不高于已装版本的包与残留。
  - app_installer_channel.dart：ChannelAppInstaller 实现 AppInstaller，经通道 superxd/app_update 调原生 AppUpdateInstaller.kt：能否安装（Android 8 起要用户允许「安装未知应用」）、打开授权设置、读安装包的包名版本号并比对签名证书、以只读授权交给系统安装器。

# 关键规则

- 本层不做业务判断：要安排哪些提醒、小组件显示哪些课由 application 下的 campus_reminders.dart、campus_widgets.dart 决定，本层只负责整体替换；要不要更新、装不装由 app_updates.dart 决定。
- 权限只在用户操作时申请（打开提醒、点“开启通知”或“准时提醒”），启动时不弹权限。

# 测试

- reminder_test.dart（课前提醒）、home_widget_test.dart（小组件）、app_update_test.dart（清单解析、安装包文件与清理）。
- 原生侧（CourseWidgets.kt、AppUpdateInstaller.kt）只有设备实测，单测里的替身证明不了原生比对写对了。
