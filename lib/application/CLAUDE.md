# application 应用编排

定位：跨领域的编排，由组合根 main.dart 创建并注入页面。分层表允许依赖 domain 与 gateway，现在只用 domain 端口（CampusGateway、提醒、小组件与更新端口）。本层决定做什么、什么时候做，具体能力交给 device、local 的实现。

# 文件职责

- campus_sync.dart：显式同步的唯一编排入口 CampusSync。
  - 先刷新学期列表，再按所选学年依次处理：先同步全部学期的课表，再逐学期同步作息和成绩；每个实例内按顺序逐项请求。
  - 页面离开、会话失效或教务限流时，在下一检查点停止；报告带出已完成项、停下前已发生的失败与未处理项。
  - 学年与数据项的选择、进度口径、未提交不报已同步，见文件内人工决策。
- campus_reminders.dart：课前提醒对账 CampusReminders。读本机的当前学期、提醒设置、课表与作息，展开未来 14 天的课程实例，整体替换系统里的提醒；没有当前学期（含退出登录）、未开启或没有通知权限时撤销本应用的全部课前提醒。
- campus_widgets.dart：桌面课表小组件的快照 CampusWidgets。读本机的当前学期、课表与作息，展开今天起 7 天的课程实例交给小组件端口；退出登录时发布空快照，缺开学日或作息时如实提示。
- campus_timetable.dart：campusTimetableToday 读本机的当前学期、课表与作息，展开今天的课程实例（CampusTimetable），由组合根经百宝箱运行时交给学习通签到推断正在上的课；未登录、没有学期、缺开学日或作息时给原因。只读本地、从不联网。
- app_updates.dart：应用内更新编排 AppUpdates，设备级，切换账号不重建。
  - 自动检查每个校园日一次（appUpdateCheckDue，按业务日界），待必须更新时每次启动都查；手动检查不受限、不认跳过。
  - 点更新才下载（缓存里已有且 SHA-256 对得上就不再下），核对 SHA-256、包名、版本号与签名证书，对不上就删包报原因；没有「安装未知应用」授权时引导开启，下载在后台完成时等回前台再拉起系统安装。
  - 端口都在 domain/app_update.dart，实现在 device 与 local（见各自 CLAUDE.md）；规则与弹窗的人工决策见 app_update.dart 与 page/app_update_dialog.dart。

# 关键规则

- 课前提醒与小组件只读本地、从不联网；对账时机由 main.dart 的 watchLocalSchedule 决定（启动恢复会话后、回到前台、切换账号或退出、本机课表相关写入后 AccountAccess.scheduleChanges），1 秒防抖。小组件配色由 main.dart 的 watchWidgetTheme 跟随显示设置单独下发。
- 同步遇到 SESSION_EXPIRED 立即停止并交给 onSessionExpired；遇到 RATE_LIMITED 本轮立即停止，不自动重试、不转登录。
- 只经 domain 端口做事，不直接访问 SQLite、教务客户端或系统 API。

# 测试

- campus_sync_test.dart、sync_ui_test.dart、transition_sync_test.dart（同步编排与同步界面）
- reminder_test.dart、home_widget_test.dart（课前提醒、小组件）；campus_timetable_test.dart（本应用课表今天的课）
- app_update_test.dart、app_update_ui_test.dart（应用更新，替身在 app_update_fakes.dart）

# 人工决策检索

- 命令：grep -rn 人工决策- lib/application
- 标记都在 campus_sync.dart：学年与数据项统一范围、进度只报已有阶段、未提交不报已同步、离开前的失败照常写入报告、限流立即停止。
