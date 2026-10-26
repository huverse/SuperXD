# device 设备能力

定位：系统能力与外部服务的适配器，只实现 domain 里定义的端口，只依赖 domain 和本目录。由组合根 main.dart 创建并注入编排层，页面不直接依赖本层。

# 文件职责

- notification_reminders.dart：NotificationReminders 实现课前提醒端口 CourseReminderPort。
  - 用 flutter_local_notifications 按校园时区定时通知；开机后由插件的接收器重新排定（清单里的 ScheduledNotificationBootReceiver）。
  - 只管理自己 id 段内的提醒（最多 reminderLimit 条），不调用 cancelAll，避免撤掉下载进度等其他通知。
  - 有精确闹钟权限时准时调度，没有时改用可能延迟的普通调度；通知渠道 course_reminder，状态栏图标 ic_stat_reminder。
  - iOS：启动时不弹通知权限，用户打开提醒时再申请；本地通知本来就准时；每个应用最多挂 64 条待发通知，capability 报 limit 64，编排按它只排最近的 64 条；前台也弹由 AppDelegate.swift 把通知中心回调交给插件；课前通知是「时间敏感」级别（专注模式下也显示，要描述文件带这项权限，[人工决策] 在 _details）。
  - iOS 的胶囊是实时活动（ios/Runner/CourseBridge.swift 的 CourseLive，iOS 16.2 起，[人工决策] 在那里）：应用在后台时系统不让自己开始，所以开着胶囊也照常发课前通知；每次打开或回到前台交来计划时，正处在提醒时刻到下课之间的那节课开始或更新实时活动，其余的结束。画面在小组件扩展 ios/CourseWidgets/CourseLiveActivity.swift（锁屏与灵动岛，课前倒数到上课、上课中倒数到下课并画进度），两边共用 ios/Shared/CourseActivity.swift。
  - 开了状态栏胶囊（live）时不经插件定时，改经通道 superxd/course_live 把计划（钟点按校园时区写好）交给原生 CourseLive.kt 发 Android 16 实时更新（OPPO 流体云按同一接口显示；插件不支持「请求提升」）。两条路同一时刻只走一条，切换时另一条交空计划。
  - CourseLive.kt：计划存私有的 superxd_course_live 偏好（已排除系统备份），条数同 reminderLimit；只排下一个时刻的一个闹钟（有精确闹钟权限时准时），到点发出或改写再排下一个；开课前倒数到开课、上课中倒数到下课（系统按 when 显示剩余分钟），setTimeoutAfter 下课自动消失；只在首次发出时响铃；用户划掉的这节不再补发；开机、应用更新、改时间或时区时由 CourseLiveReceiver 重新处理。能力查询给用户是否允许（canPostPromotedNotifications）与系统有没有实时更新（允许，或有实时更新设置页可去开；Android 16 首版没有这一页，不给开关），「开启胶囊」打开这个设置页（清单 queries 里声明了它）。
- home_widget_publisher.dart：HomeWidgetPublisher 实现桌面小组件端口 CourseWidgetPort。
  - 经通道 superxd/course_widget 把快照与配色（JSON）交给原生侧 CourseWidgets.kt，存进私有的 superxd_course_widget 偏好（已排除系统备份）。
  - 钟点、日期在这里按校园时区算好；原生侧只用快照带的 campusTimeZone 判断“今天”，按系统时间挑当前与下一节。
  - 原生侧在上下课时刻与校园日界用非精确闹钟（不需要权限，系统可能推迟最多约 10 分钟）刷新；改系统时间或时区时也重画；桌面上没有小组件时撤销闹钟。
  - 没用 home_widget 插件：它强制引入 Glance 与 Compose 运行时，而这里只需保存快照与刷新 RemoteViews。
  - iOS：CourseBridge.swift 把同一份快照与配色写进 App Group 共享容器的 widget 目录（排除 iCloud 备份，同安卓不备份小组件数据；不用共享的 UserDefaults，那份会进备份）再让系统重排时间线；小组件在扩展 ios/CourseWidgets（WidgetKit，最低 iOS 16.2）：下一节（小号与锁屏）、接下来两节（中号）、今日课程（大号），规则与提示文案同安卓（home_widget_test.dart 守护文案一致），时间线排到 24 小时内的上下课、校园日界与快照过期时刻。App Group 名不写死，由 ios/Shared/SharedGroup.swift 从安装包的描述文件读（自签证书各人不同）。

- 应用内更新的三个适配器，由 application/app_updates.dart 编排：
  - relay_release_feed.dart：RelayReleaseFeed 实现 AppReleaseFeed（packages 为假时不要安装包：iOS 按 arm64 取同一份清单、只看版本，弹窗给「去发布页下载」，[人工决策] 在 main.dart 的 appUpdates），GET 自建中转的 /v1/app/releases/<渠道>?abi=（免签名），单次 15 秒超时、响应上限 64KB、不重试；RELEASE_NOT_FOUND 当这个渠道还没有发布。parseAppRelease 把清单当外部输入逐项校验，安装包地址只认本服务的下载路径。appAbiName 把正在运行的架构映射成安装包架构名。
  - app_package_files.dart：CacheAppPackageFiles 实现 AppPackageFiles。安装包放在缓存的 app_update 文件夹（原生 FileProvider 只开放这里），只留一个版本；background_downloader 的独立命名空间 superxd_update 下载（回调与百宝箱的下载互不相干），有通知权限时以前台任务跑并在通知栏显示进度（规则同百宝箱 background_transfer.dart）；SHA-256 在后台 isolate 里算；prune 删掉版本号不高于已装版本的包与残留。
  - app_installer_channel.dart：ChannelAppInstaller 实现 AppInstaller，经通道 superxd/app_update 调原生 AppUpdateInstaller.kt：能否安装（Android 8 起要用户允许「安装未知应用」）、打开授权设置、读安装包的包名版本号并比对签名证书、以只读授权交给系统安装器。

- relay_note_feed.dart：RelayNoteFeed 实现开发者的话的拉取端口 DeveloperNoteFeed：GET 自建中转的 /v1/app/notes（免签名、不带任何标识），单次 15 秒超时、响应上限 512KB、不重试；清单交给 domain 的 decodeDeveloperNotes 校验。
- relay_reward_client.dart：RelayRewardClient 实现节日抽签端口 FestivalRewardClient：POST 自建中转的 /v1/rewards/<活动>/draw（免签名），只发参与号与近 30 天打开过的天数，单次 15 秒超时、响应上限 8KB、不重试；parseFestivalDraw 把结果当外部输入校验。
- picture_export.dart：publishPicture 把缓存里的一张图经原生一次性导出（ToolboxFileExporter.kt，通道 superxd/toolbox_files）存进 Download/SuperXD，同名已存过直接算存好；开屏画作的「保存到相册」用，由组合根交给 local/painting_library.dart；节日奖品的「保存二维码」也经它（组合根的 saveRewardPicture）。
- app_shortcuts.dart：ChannelAppShortcuts 实现 AppShortcutPort。iOS 是 AppShortcuts.swift：只有长按图标的菜单、没有添加到桌面（组合根不给 pinShortcut），菜单图标只能用 SF Symbols，入口 id 到图标名在文件里登记（新增入口要一起加）；按插件登记收场景回调，冷启动的入口先记下给 Dart 取一次。安卓经通道 superxd/app_shortcuts 调原生 AppShortcuts.kt（ShortcutManager）：动态快捷方式整份替换（同 id 的桌面快捷方式跟着换名字与图标）；requestPinShortcut 由桌面弹窗请用户确认，桌面不支持返回 false；冷启动带来的入口 id 由 MainActivity 先记下、Dart 取一次；应用在后台时经 onNewIntent 调 launch 交回。启动标志用 CLEAR_TOP 加 SINGLE_TOP，只把已有界面拉到前台，不加 CLEAR_TASK（那会整个冷启动）。
- diagnostic_device.dart：本机诊断日志用到的系统能力，由组合根交给 local/diagnostic_log.dart 与 app_diagnostics.dart：readDeviceEnvironment 经 device_info_plus 读系统版本与机型（写进日志包的运行环境）；publishDiagnosticArchive 把缓存里打好的 zip 经原生一次性导出（ToolboxFileExporter.kt，与百宝箱共用通道 superxd/toolbox_files）存进 Download/SuperXD；readExitReasons 经通道 superxd/diagnostics 调原生 ProcessExitReasons.kt，读系统记下的最近几次进程退出原因（Android 11 起的 ApplicationExitInfo，只返回给定时刻之后的，ANR 附主线程堆栈，从 "main" 那行起 80 行、最多 8KB，一条读不出只把这条置空）；每次启动都调，通道处理放在后台线程（MainActivity.kt 的 makeBackgroundTaskQueue），不占主线程。iOS 上运行环境读 iosInfo；退出原因由 ProcessExitReasons.swift 订阅 MetricKit 诊断报告（崩溃记 CRASH、卡死记 ANR，CPU 与写盘超限按后台记），系统在之后某次启动才交来，存进 device_only/exit_reasons.json、只留最近 20 条。
- backup_exclusion.dart：excludeFromBackup 只在 iOS 由组合根调用：iOS 没有安卓 data_extraction_rules.xml 那样的规则文件，组合根把同一批只属于本机的目录（先建好）与私信库交给原生 ios/Runner/DeviceOnlyData.swift（通道 superxd/backup）标记不进 iCloud 备份与换机迁移；会被整个替换的文件（开发者设置）放进标记过的 device_only 目录。DeviceOnlyData.swift 另在每次新装后第一次启动时清掉钥匙串里上次安装留下的条目（iOS 卸载不删钥匙串），要赶在 Dart 读钥匙串之前，由 AppDelegate.swift 调用。

# 关键规则

- 本层不做业务判断：要安排哪些提醒、小组件显示哪些课由 application 下的 campus_reminders.dart、campus_widgets.dart 决定，本层只负责整体替换；要不要更新、装不装由 app_updates.dart 决定。
- 权限只在用户操作时申请（打开提醒、点“开启通知”或“准时提醒”），启动时不弹权限。

# 测试

- reminder_test.dart（课前提醒）、home_widget_test.dart（小组件）、app_update_test.dart（清单解析、安装包文件与清理）。
- 原生侧（CourseWidgets.kt、CourseLive.kt、AppUpdateInstaller.kt）只有设备实测，单测里的替身证明不了原生比对写对了；ColorOS 流体云要在 OPPO 真机上看。
