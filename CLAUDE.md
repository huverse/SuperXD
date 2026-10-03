# SuperXD 项目索引

本文件与 lib 下各模块的 CLAUDE.md 共同组成项目索引。根文件记录全局结构、跨模块不变量和改动流程；模块文件记录文件职责、关键流程、库表和限额。具体细节以代码注释和带 [人工决策] 标记的注释为准，索引只提供地图和指针。

- [人工决策-2026-09-29 21:40:28] 索引采用仓库内分层 CLAUDE.md（根目录加 lib 各模块），授权 AI 创建，并在每次改动时同步维护。用户全局 CLAUDE.md 仍由 AI 只提建议、由人工修改。
- 文件级登记由 test/project_structure_test.dart 兜底，有两条检查：
  - lib 下每个 dart 文件都要在最近的模块 CLAUDE.md 里按文件名登记，所在模块没有 CLAUDE.md 时登记在本文件。
  - 索引中提到的 dart 或 kt 文件必须真实存在。
- 模块索引共 8 个：lib/domain、lib/edu、lib/local、lib/gateway、lib/device、lib/page、lib/theme、lib/toolbox 下各一个 CLAUDE.md。lib/application 与根目录文件登记在本文件。

# 定位

- 校园课表与成绩 Flutter 应用。当前只有 Android 宿主，对接单所学校的 Kingo 教务系统；另有免教务登录的百宝箱，目前提供短视频解析与下载。
- 当前阶段为私有 Alpha 内测。Flutter 3.47.2 / Dart 3.13.2，依赖锁定在 pubspec.lock。
- 相关文档：
  - 设计语言：UITEMP/design_language.md
  - 发布、签名与本地开发：README.md
  - 协作流程：CONTRIBUTING.md
  - 变更记录：CHANGELOG.md

# 分层与依赖方向

目录即分层，依赖只许自上而下，由 test/project_structure_test.dart 守护。出现反向依赖时先重新划分职责，不要绕过检查。

- 根目录组合根：main.dart、router.dart、app_session.dart，可依赖任何层。
- page 页面：可依赖 domain、application、gateway、local、theme 与 app_session.dart。
  - 页面只通过 domain 端口 CampusGateway 和账号接口 AccountAccess 访问业务，不直接接触 SQLite、KingoClient 或 cookie。
  - 现有例外只有外观页读写 DisplaySettings。
- toolbox 百宝箱：设备级、免登录，可依赖 domain、theme，不依赖教务相关任何层。
- application 应用编排：可依赖 domain、gateway。
- device 设备能力：系统通知、桌面小组件等适配器，只实现 domain 端口、只依赖 domain，由组合根注入；页面不直接依赖。
- gateway 网关：负责账号生命周期与教务网关实现，可依赖 domain、edu、local。
- edu 教务协议与页面解析：可依赖 domain。
- local 本地存储：可依赖 domain。
- domain 领域核心：纯 Dart 的类型、端口与规则，只依赖自身。
- theme 主题与通用视觉组件：只依赖自身，外加日志出口 domain/campus_log.dart。

# 组合根与路由门禁

- main.dart 的启动顺序：
  1. 把日志出口注入为 debugPrint，再初始化时区库、图标与第三方许可。
  2. 打开 AccountStore，组装 AppSession（内含 AccountGateway 与 SecureCredentialStore）和 DisplaySettings。
  3. runApp 之后，不等待地初始化玻璃渲染，再恢复会话。
- 账号代次：SuperXdApp 以 session.generation 作 key 重建内部账号应用。账号切换时，路由和页面内存状态整体丢弃，旧账号状态不会带入新账号。
- router.dart 的门禁：
  - 会话恢复完成前停在 /boot。
  - 未登录时只允许 /login、/legal 下的法务页、/toolbox 与已注册工具路由，其余都重定向到 /login。
  - 已登录时访问 /login 回到 /today。
  - 底栏壳有今天、服务、消息、我的 4 个分支，外面包 LegacyImportGate。
  - /schedule、/grades、/switch-account、法务页和百宝箱都推入根导航器。
- app_session.dart：
  - 把 AccountAccess 的账号变化转成路由刷新，并暂存一次性提示。
  - expire 只让发起时的那个代次失效，旧页面不能误登出新账号。
- 页面从路由拿到两个回调：isAccountCurrent 判断异步结果是否仍属于当前账号，onSessionExpired 负责登出。异步结果回来后要先检查，再写界面。
- application/campus_sync.dart（CampusSync）：显式同步的唯一编排入口。
  - 先刷新学期列表，再按所选学年依次处理：先同步全部学期的课表，再逐学期同步作息和成绩。
  - 页面离开、会话失效或教务限流时，在下一检查点停止，报告里带出已完成项、停下前已发生的失败与未处理项。
  - 学年与数据项的选择、进度口径、未提交不报已同步，这几条规则都见该文件的人工决策注释。
- application/campus_reminders.dart（CampusReminders）：课前提醒对账。
  - 读本机的当前学期、提醒设置、课表与作息，展开未来 14 天的课程实例，整体替换系统里的提醒；只读本地，从不联网。
  - 对账时机由 main.dart 的 watchLocalSchedule 决定：启动恢复会话后、回到前台、切换账号或退出、本机课表相关写入后（AccountAccess.scheduleChanges），1 秒防抖。
  - 没有当前学期（含退出登录）、未开启或没有通知权限时，撤销本应用的全部课前提醒。
- application/campus_widgets.dart（CampusWidgets）：桌面课表小组件的快照。
  - 读本机的当前学期、课表与作息，展开今天起 7 天的课程实例交给小组件端口；只读本地，从不联网。对账时机与课前提醒相同。
  - 退出登录时发布空快照，小组件不显示上一个账号的课；缺开学日或作息时如实提示。
  - 配色由 main.dart 的 watchWidgetTheme 跟随“配色”和“深浅色”设置单独下发；原生侧见 CourseWidgets.kt。

# 跨模块不变量（改动前逐条自查）

1. 账号隔离
   - 账号身份由教务来源 URL 加教务确认的学号组成。每个账号按身份哈希使用独立的 SQLite 库，并校验库的 owner。
   - 账号索引库只存账号列表、活动账号指针和旧库认领记录。
   - 切换、退出、导入都要经过 AccountGateway 的切换锁。切换时旧上下文先停止接收新请求，并等在途请求全部结束。
2. 网关不抛异常
   - CampusGateway 的所有方法都返回 GatewayResult。失败时带一个在 domain/gateway_code.dart 登记过的错误码。
   - 页面与同步只按错误码分支，message 只用来展示。新错误码要先登记再使用。
3. 会话失效
   - 任何环节拿到 SESSION_EXPIRED，都立即停止后续请求，并交给 onSessionExpired 处理。
   - 用户开启了记住账号时，AccountGateway 自动恢复登录一次，并重放这次请求。恢复失败或重放后仍失效，就不再自动恢复。
4. 同步不误覆盖
   - 教务页面只有明确的无课、无成绩语义才当作空结果。权限、维护、截断或无法识别的页面一律报错，并保留本地数据。
   - 本地已有自定义课表版本时，同步前要用户确认覆盖。
   - 采用其他学期的作息须用户明确确认；普通同步不改变已有的作息绑定。
5. 课表版本
   - 编辑、恢复和确认覆盖都要带 expectedRevisionId，在同一事务里核对当前 head（乐观锁）。不一致时返回 REVISION_CONFLICT。
   - 每学期最多保留 100 个版本，当前 head 和最近一次教务基线受保护，不会被清理。
6. 时间
   - 绝对时刻一律存为 UTC 的 ISO 字符串。
   - 校园时区只在 domain/campus_clock.dart 的 campusTimeZone 一处定义。今天、周次、倒计时等业务日界都经 campus_clock 计算。
   - 展示时间用 formatCampusTimestamp。
7. 凭据
   - 用户明确勾选记住账号且认证成功后，才把凭据写入系统安全存储。
   - 业务 SQLite、账号索引和日志一律不存密码。
   - 用户关闭记住账号或主动退出时，立即删除凭据。
8. 设备级数据
   - 百宝箱、下载任务，以及配色、字体、字号、深浅色、玻璃效果和自定义壁纸都属于设备，切换账号时保留。
   - 自定义壁纸只经系统照片选择器读取用户选中的一张，复制到应用私有目录，不上传、不申请存储权限。
   - 桌面小组件显示的是当前账号的课，跟着账号切换，退出登录即清空；只有它的配色跟随设备设置。
   - 百宝箱不读取教务凭据或 cookie。
   - 第三方解析来源逐个来源、按授权版本单独征得同意。自动模式只尝试已启用且已同意的来源。
9. 对外网络
   - 教务请求：单次 25 秒超时，只允许同源地址。
   - 每个 CampusSync 实例内按顺序逐项请求；今天页和成绩页各持有一个实例。成绩同步与其他教务网络请求互斥，冲突时返回 SYNC_BUSY。
   - 除了会话自动恢复后的一次重放，其他请求都不自动重试。
   - 教务限流：课表、成绩数据查询在任意 10 秒内最多发 6 次，超出的排队。教务仍提示“请求太过频繁”时报 RATE_LIMITED，本轮同步立即停止，由用户稍后再同步。
   - 百宝箱解析：总预算 30 秒，单次响应上限 1MB。媒体地址必须是公网 https，拒绝本机和内网地址。
10. 数据保留
    - 课表版本：每学期 100 个。
    - 解析历史：只存本机，最多 80 条且保留 30 天；默认开启，用户可关闭。
    - 下载记录：已结束的最多保留 100 项且 30 天。创建超过 24 小时仍未完成的任务，在启动时取消。
    - 自定义壁纸：只保留当前一张，不超过 20MB；换图或恢复云雾时删除，启动时清理残留；选图插件留在缓存里的副本用完即删。
    - 成绩：单次载荷上限 4MB，课程上限 1000 条。
    - 课前提醒：只安排未来 14 天、最多 128 条，每次对账整体替换；提醒设置每学期一行。
    - 日历导出：单次最多 5000 个事件；缓存里只留最近一次导出的文件，下次导出前清空。
    - 桌面小组件：快照只覆盖今天起 7 天、最多 200 次课，每次整体替换；过期后提示打开应用。桌面上没有小组件时不留刷新闹钟。
    - 新增只增不删的数据时，必须同时给出上限或清理策略。
11. 日志
    - 只经 domain/campus_log.dart 的 campusLog 输出。应用入口必须注入 debugPrint，日志才会进入 logcat。
    - 格式为 [模块] action=... errorType=...，错误附完整堆栈。不写原始 HTML、链接或凭据。
    - 由 test/project_structure_test.dart 守护。
12. 界面实现
    - 确认和提示统一使用 theme/campus_transitions.dart 的 showCampusConfirm 与 showCampusNotice。
    - setState 回调不得返回 Future；给 Future 字段赋值时用块体。由 test/code_conventions_test.dart 守护。

# 界面约定（来自用户反馈，细节见自动记忆）

- 耗时操作在发起位置原地显示状态：等待、进度、可暂停或取消，完成后原地切换为下一步动作（如“打开”）。
- 可点击元素一律做成带图标的按钮。状态信息只读，不用主色；主色只留给按钮和图标。整组操作和破坏性操作收进⋯菜单，并保留确认。
- 会变化的列表按稳定键排序，状态变化时条目不跳动。
- 文案简洁，少放说明性文字。账号授权、旧数据归属、删除或覆盖确认以及必要的错误文案必须保留。
- 手势、方向等偏离常见习惯的要求，先提醒用户确认再实现。
- 文字最小 14px。带浮动标签的输入框，上方间距要随字号缩放（campusFieldGap）。

# 改动前检查清单

1. 读本文件和涉及目录的 CLAUDE.md，确认改动落在哪一层、依赖方向是否允许。
2. 在涉及的文件及其调用方检索人工决策：grep -rn 人工决策- lib test android/app。
   - 修改带标记的代码前，先请用户确认该决策仍然有效。
   - 用户新确认的决策，在代码处加 [人工决策-北京时间] 注释，时间用 TZ=Asia/Shanghai date 获取，精确到秒。
3. 查自动记忆（MEMORY.md 索引）里的相关主题：测试授权边界、验收证据边界、被否决的视觉方案、平台运行证据、百宝箱第三方结论、版本控制授权。
4. 对照上面的跨模块不变量逐条自查。遇到业务取舍，先向用户说明，并给出方案让用户选择。
5. 改完后验证：
   - 运行 flutter analyze 和受影响的测试，必要时跑全量 flutter test。
   - 本机默认镜像会改写 pubspec.lock，所以 flutter 命令一律加 PUB_HOSTED_URL=https://pub.dev 前缀，提交前确认 pubspec.lock 没有变化。
   - 影响界面或运行行为的改动，要在模拟器上查看实际效果。
6. 同步索引：
   - 新增、删除、搬迁文件，或改变职责、流程、库表、限额时，在同一提交里更新对应的 CLAUDE.md。
   - 在 CHANGELOG 的 Unreleased 下记一条。

# 测试地图（改哪里先跑哪些）

- 结构与规范：project_structure_test.dart、code_conventions_test.dart
- 账号与会话：
  - account_isolation_test.dart、account_lifecycle_test.dart、account_store_test.dart
  - remembered_session_test.dart、legacy_import_test.dart、kingo_gateway_test.dart
- 教务协议与解析：contract_test.dart、kingo_client_response_test.dart、sync_boundary_regression_test.dart、grades_test.dart
- 课表数据：schedule_edit_test.dart、schedule_version_test.dart、schedule_migration_test.dart、bells_persistence_test.dart、period_day_test.dart、schedule_calendar_test.dart
- 同步编排与同步界面：campus_sync_test.dart、sync_ui_test.dart、transition_sync_test.dart
- 课程实例、课前提醒、日历导出与桌面小组件：reminder_test.dart、calendar_export_test.dart、home_widget_test.dart
- 页面交互：
  - today_navigation_test.dart、today_date_transition_test.dart、schedule_experience_test.dart、schedule_editor_ui_test.dart
  - grades_ui_test.dart、form_spacing_test.dart、navigation_drag_test.dart、shell_layout_test.dart
  - legal_page_test.dart、course_clock_performance_test.dart
- 主题与显示设置：atmosphere_test.dart、campus_glass_test.dart、campus_glass_button_test.dart、campus_motion_test.dart、dark_mode_test.dart、appearance_settings_test.dart、wallpaper_test.dart
- 百宝箱：toolbox_widget_test.dart、toolbox_download_test.dart、toolbox_media_features_test.dart、short_video_parser_test.dart、media_image_test.dart
- 测试支撑：
  - fixture_campus_gateway.dart：合成数据教务网关，读取 assets/fixtures。
  - toolbox_test_support.dart、form_layout_support.dart
- tool 下的手动入口，不进 CI：
  - verify_edu.dart、verify_grades.dart：访问真实教务，只在授权环境手动运行。
  - verify_toolbox.dart：Android 原生下载验证。
  - schedule_smoke.dart、glass_preview.dart、motion_preview.dart
  - motion_release_test.dart：检查发布包的图标字体。

# 已知行为与约束（本轮只记录，不改动）

- 单校写死：教务地址是 kingo_client.dart 的 kingoBase，作息解析里写死了校名（parse_bells.dart）。换校要把来源改成配置，并迁移账号身份键，因为身份键包含来源 URL。
- CampusBackground 是空包装，背景统一由 CampusAtmosphere 绘制，保留它只是为了兼容现有调用点。
- 以下公开方法只有测试或工具在用，删除前先改测试：
  - AppDatabase 的 revisionSummaries、termStartDate、gradesPayload、insertRevision、openMemory
  - schedule_calendar.dart 的 semesterDays、weekDates
  - kingo_des.dart 的 strDec
- 账号库开启了 SQLite 外键：schedule_head 引用 schedule_revision，所以裁剪版本时必须保护 head。
- 性能观察项，没有真机 profile 证据前不要改动：
  - 结果页和下载页随进度通知整页重建
  - FrostTexture 逐点绘制颗粒
  - 成绩响应分块累加
- 平台：只有 Android 宿主。验证只在模拟器（API 36、API 34）上做过，真机和 iOS 都未验收。原生导出通道见 MainActivity.kt、ToolboxFileExporter.kt 与 CalendarExporter.kt（日历文件只经 CalendarFileProvider 开放缓存 calendar_export 文件夹）；桌面小组件见 CourseWidgets.kt。
