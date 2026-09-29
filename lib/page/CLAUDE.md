# page 页面

定位：Flutter 页面与页面级组件。
- 依赖范围：domain（端口与类型）、application（同步编排）、theme（视觉组件）和 app_session.dart。gateway 只用 account_access.dart，local 只用 display_settings.dart。
- 页面只调用 CampusGateway 和 AccountAccess，不直接读写数据库，也不直接调用教务客户端。

# 文件职责

- 壳层与导航：
  - shell_page.dart：
    - 底栏壳 ShellPage，包含今天、服务、消息、我的四个分支。
    - 可拖动底栏 DragNavigationBar，悬浮在安全区之上；内容层延伸到玻璃下方，底栏占位作为各页的底部安全区。
  - animated_branches.dart：AnimatedBranches 负责分支切换转场，保留每个分支的 Navigator。
  - section_pages.dart：
    - 服务页：课表、成绩、百宝箱三个入口。
    - 消息页：通知、私信，当前为占位。
    - 我的页：界面设置、关闭记住账号、切换账号、导入旧版本数据、退出登录、开源与第三方声明。
- 今天：
  - today_page.dart：今天页 TodayPage。
    - 读取当前学期的课表和作息，按日浏览。
    - 同步按钮（点按或长按）打开同步范围选择，流程为 chooseSyncSelection → CampusSync.run → showCampusSyncReport。
    - 包含作息来源确认弹窗，缺开学日时引导设置。
    - 同步中离开今天页时，结果先暂存，回来后再提示。
  - today_day_navigation.dart：上下拖动切日的手势 TodayDayNavigation，拖动阈值 64，上限 120。
  - today_date_transition.dart：TodayDateTransition 让切日时的日期和正文按同一进度纵向交接。
  - course_cards.dart：当日节次卡片 CourseDayCards，分有课卡和空档卡，长按展开；另有倒计时 courseCountdowns。
  - live_clock.dart：全局分钟时钟 LiveClock，在每个整分钟唤醒，应用进入后台时暂停。
  - date_rail.dart：日期横条 DateRail。
- 课表：
  - schedule_page.dart：课表页 SchedulePage。
    - 支持天、学期、学年三种范围，可设置开学日。
    - 无课时段可新增课程或安排已有课程，也可进入课程管理。
  - schedule_calendar.dart：课表页月份轨道与周次轨道的纯函数计算。
  - schedule_editor_page.dart：课程管理 ScheduleEditorPage，可新增、编辑、删除（可撤销）、清空、建立空课表，并提供历史版本入口。
  - course_editor_page.dart：单门课程编辑 CourseEditorPage，编辑名称、教师、学分和多个上课时段。
  - schedule_history_page.dart：课表历史版本 ScheduleHistoryPage。按序号分页列出版本，可预览与当前的差异，恢复时带乐观锁。
  - term_start_dialog.dart：开学日设置弹窗 editTermStart。
- 成绩：
  - grades_page.dart：成绩页 GradesPage。
    - 展示学年与学期汇总，以及有效成绩和原始成绩。
    - 支持筛选、排序和搜索；在这个页面只同步成绩。
- 同步：
  - sync_selection_dialog.dart：同步范围选择 chooseSyncSelection。
    - 学年和同步内容都可多选。
    - 默认读取本地学期列表，用户点刷新时才联网刷新。
  - campus_sync_dialogs.dart：同步结果弹窗 showCampusSyncReport，展示结果和未处理项，可重新登录或重新同步。
- 账号与设置：
  - login_page.dart：登录页 LoginPage，也用于切换账号。包含验证码、记住账号确认，以及百宝箱和法务入口。
  - account_dialogs.dart：旧版本数据导入确认 showLegacyImport，以及登录后自动提示导入的 LegacyImportGate。
  - appearance_page.dart：界面设置 AppearancePage，调整字号、配色、字体和深浅色。
  - legal_page.dart：服务协议与隐私政策 LegalPage，内容是私有 Alpha 内测说明。
  - licenses_page.dart：开源许可列表 CampusLicensesPage 和应用署名 GalaxyousAttribution。
  - third_party_page.dart：第三方声明全文 ThirdPartyPage，读取 assets/third_party_notices.txt。

# 关键规则

- 异步结果写界面前先检查 mounted，涉及账号的再检查 isAccountCurrent；遇到 SESSION_EXPIRED 交给 onSessionExpired 处理。
- 分支页用 TickerMode 判断是否可见。今天分支重新可见时只刷新本地数据、不联网，并展示暂存的同步报告。
- 页面平时只读本地（read 系列方法）。联网只能由用户显式触发：
  - 同步统一经 CampusSync 编排，成绩页只同步成绩。
  - 同步范围弹窗里的刷新学期，也需要用户点击才会联网。
- 今天页只读课表，编辑入口只在课表页。
- 有课卡和无课卡都只在长按时展开，单击不展开。
- 弹窗统一走 showCampusDialog 系列：
  - 确认用 showCampusConfirm。
  - 提示用 showCampusNotice。
  - 耗时操作用 showCampusWaiting。
- setState 回调不得返回 Future。
- 切日、底栏拖动等手势：拖动中只预览不提交；正常松手和系统取消要分别处理。
- 方向或手势类改动，先对照 today_page.dart、today_day_navigation.dart 中的人工决策注释，以及记忆里被否决的视觉方案。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/page
- 本目录的标记集中在以下几处：
  - 切日方向与交接
  - 底栏拖动与安全区
  - 课程卡长按
  - 无课时段新增
  - 成绩同步范围与学年汇总
  - 旧库导入确认
  - 法务说明
  - 同步中止提示
