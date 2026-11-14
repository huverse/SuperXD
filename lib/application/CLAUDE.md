# application 应用编排

定位：跨领域的编排，由组合根 main.dart 创建并注入页面。分层表允许依赖 domain 与 gateway，现在只用 domain 端口（CampusGateway、提醒、小组件与更新端口）。本层决定做什么、什么时候做，具体能力交给 device、local 的实现。

# 文件职责

- campus_sync.dart：显式同步的唯一编排入口 CampusSync。
  - 先刷新学期列表，再按所选学年依次处理：先同步全部学期的课表，再逐学期同步作息和成绩；每个实例内按顺序逐项请求。
  - 页面离开、会话失效或教务限流时，在下一检查点停止；报告带出已完成项、停下前已发生的失败与未处理项。
  - 学年与数据项的选择、进度口径、未提交不报已同步，见文件内人工决策。
  - 课表和本地改过的版本冲突时交给 resolveSchedule 决定 ScheduleResolution（KeepLocal、TakeEdu、MergeEdu），settle 落库，自动同步与打扰时机共用。activeRuns 是本进程里正在跑的轮数，自动同步据此让路；让路的那轮（yields）还没收尾时，手动同步先等它停下再发请求，不撞上它在途的请求。
- auto_sync.dart：自动同步的编排 AutoSync（设备级，经账号门面跟着当前账号，人工决策见 domain/auto_sync.dart）。
  - runIfDue：到期（autoSyncDue）且没有别的同步在跑才同步一轮，范围取设置里的学年与内容（当前学年按本机的当前学期取）；同一个账号同一时刻只跑一轮，有人手动同步就在下一检查点让路。
    - 开跑时记下账号代次（组合根注入 generation）：中途换了账号就在下一检查点停下，结果不记、暂存不读（门面跟着当前账号走，不变量 1）；换账号后再按新账号看一次到没到期。
    - keepGoing 由组合根给（后台任务的时限、安卓系统叫停、前台那份已经起来），返回假就在下一检查点停下。
  - 冲突不覆盖：教务这份和上次同步的一样（只是自己改过）就悄悄保留本地、以后不问；教务确有新改动才留到打扰时机问（held）。作息来源一律不自动改。
  - 上次结果按报告记：登录过期记 paused（不转登录页、本机会话留着，见 keepSessionDuring；后台不到期，用户打开应用时到了间隔试一次，重新登录才清掉）、没连上网记 network（15 分钟后可再试）、限流记 limited、其余失败记 failed 并写明哪一项；让路或被叫停没做完的一轮不算成功也不算失败，上次结果照旧。
  - accountChanged 与 save 按设置排好或撤掉系统后台任务（端口 BackgroundSyncScheduler），系统接口出错只记日志。settle 处理打扰时机里选的结果；stillHeld 在弹之前从当前账号的本机库重读暂存的那份（手动同步过、换过账号就没了）。accountChanged 先清掉上一个账号的设置与暂存。
- campus_reminders.dart：课前提醒对账 CampusReminders。读本机的当前学期、提醒设置、课表与作息，展开未来 14 天的课程实例，整体替换系统里的提醒；没有当前学期（含退出登录）、未开启或没有通知权限时撤销本应用的全部课前提醒。开了状态栏胶囊且系统有实时更新时提醒发成实时更新（OPPO 流体云），[人工决策] 在类上方。
- campus_widgets.dart：桌面课表小组件的快照 CampusWidgets。读本机的当前学期、课表与作息，展开今天起 7 天的课程实例交给小组件端口；退出登录时发布空快照，缺开学日或作息时如实提示。
- campus_timetable.dart：campusTimetableToday 读本机的当前学期、课表与作息，展开今天的课程实例（CampusTimetable），由组合根经百宝箱运行时交给学习通签到推断正在上的课；未登录、没有学期、缺开学日或作息时给原因。只读本地、从不联网。
- app_updates.dart：应用内更新编排 AppUpdates，设备级，切换账号不重建。
  - 自动检查每个校园日一次（appUpdateCheckDue，按业务日界），待必须更新时每次启动都查；手动检查不受限、不认跳过。自动检查时可选更新不在这一批（组合根注入的 inBatch，即 Rollouts.inUpdateBatch）就当没有，手动检查与必须更新不受批次限制。
  - 点更新才下载（缓存里已有且 SHA-256 对得上就不再下），核对 SHA-256、包名、版本号与签名证书，对不上就删包报原因；没有「安装未知应用」授权时引导开启，下载在后台完成时等回前台再拉起系统安装。
  - 端口都在 domain/app_update.dart，实现在 device 与 local（见各自 CLAUDE.md）；规则与弹窗的人工决策见 app_update.dart 与 page/app_update_dialog.dart。

- developer_notes.dart：开发者的话的编排 DeveloperNotes（设备级）：自动拉取间隔至少 developerNoteRefreshGap（一小时，下拉刷新不受限）、同一时刻只拉一次、失败照旧显示上次拉到的；已读与弹过记在本机（弹出一封时当时所有的信都记成弹过、只有这封记成读过）。人工决策见 domain/developer_note.dart。
- festivals.dart：节日的编排 Festivals（设备级）：今天该播哪一次（在节日里、没播过）、启动与回到前台记今天打开过（只留近 30 天）、按需登记抽奖身份（prepare：有抽奖的节日开始前 7 天到结束之间、还没登记成功就生成密钥并登记一次，节日都过了就撤下；两者都不是时不碰安全存储、不联网）、抽签（有抽奖、配了中转、抽奖身份已登记、结果没定时才抽，同一时刻只发一次；登记还在路上先等它；连不上或没登记成功不记，中转不认这台设备时记回没登记）、抽中的奖品（没揭晓的等打扰时机揭晓，节日结束后 3 天删）。refresh 是同意协议与政策后、每次回到前台由组合根调的：先 prepare 再补抽播过的。人工决策见 domain/festival.dart。
- app_accounts.dart：应用账号的编排 AppAccounts（设备级，切换教务账号不重建；三项用户决定的 [人工决策] 在类上方）：按当前教务身份读本机记着的应用账号（跟着教务切换，换账号时丢掉没答完的验证码）；signIn 先向网关要口令摘要（没记住账号返回要密码，页面请用户输一次），经 AppAccountClient 交中转核对，要验证码时 answerCaptcha、refreshCaptcha（重新发起一次）接着做，成功后用同一个密码经 AccountAccess.refreshSession 重登教务（中转代登录挤掉了本机会话）；signOut、deleteAccount 由账号页发起；forget 由组合根在用户退出教务时调；check 在同意协议与政策后、回到前台时由组合根调，登录着且隔 checkGap（一天）才联网，别处注销了退回未登录。accountId 是灰度与分批更新分桶用的账号号。
- rollouts.dart：灰度的编排 Rollouts（设备级，人工决策见 domain/rollout.dart）：本机判定，主体是应用账号号（组合根注入，没登录用本机随机编号）；enabled 判功能开关（没配用调用方给的默认值）；inUpdateBatch 判分批更新（配置里同名开关覆盖清单的放量表：暂停、直接全量、整版关停）；refresh 在同意协议与政策后、回到前台时由组合根调，两次至少隔 refreshGap（一小时），失败照旧用上次的；没配中转时不联网。
- app_moments.dart：打扰时机 AppMoments（设备级）：一次只出现一件，先后是节日动画、没揭晓的奖品、自动同步留下的课表冲突、新信；决定节日动画、新信这类不是用户要的内容什么时候出现。业务条件在这里：每次回到前台最多一件、从快捷入口进来的那次前台不出现、上下课安静期里不出现（安静期结束时提醒组合根再看一眼）；界面条件在组合根 main.dart 的 _promptMoment。next 只看不记，真的弹出来了再 begin。人工决策在类上方。

# 关键规则

- 课前提醒与小组件只读本地、从不联网；对账时机由 main.dart 的 watchLocalSchedule 决定（启动恢复会话后、回到前台、切换账号或退出、本机课表相关写入后 AccountAccess.scheduleChanges），1 秒防抖。小组件配色由 main.dart 的 watchWidgetTheme 跟随显示设置单独下发。
- 同步遇到 SESSION_EXPIRED 立即停止并交给 onSessionExpired；遇到 RATE_LIMITED 本轮立即停止，不自动重试、不转登录。
- 只经 domain 端口做事，不直接访问 SQLite、教务客户端或系统 API。

# 测试

- campus_sync_test.dart、sync_ui_test.dart、transition_sync_test.dart（同步编排与同步界面）；auto_sync_test.dart（到期规则、账号库、自动同步编排与打扰时机的先后）；sync_merge_test.dart（合并页、手动同步流程、打扰时机弹窗、自动同步设置）
- reminder_test.dart、home_widget_test.dart（课前提醒、小组件）；campus_timetable_test.dart（本应用课表今天的课）
- app_update_test.dart、app_update_ui_test.dart（应用更新，替身在 app_update_fakes.dart）
- app_account_test.dart（应用账号的中转客户端、编排与账号页）
- rollout_test.dart（灰度编排、分批更新按批次）
- developer_notes_test.dart（开发者的话的拉取、已读与打扰时机）；festival_test.dart（节日编排、抽签与打扰时机的先后）；account_lifecycle_test.dart（「我的」页入口与小圆点、新信在什么界面条件下弹）

# 人工决策检索

- 命令：grep -rn 人工决策- lib/application
- campus_sync.dart：学年与数据项统一范围、进度只报已有阶段、未提交不报已同步、离开前的失败照常写入报告、限流立即停止。
- campus_reminders.dart：状态栏胶囊（流体云）的接入方式、显示时段与胶囊内容。
- app_moments.dart：打扰时机的业务条件、课表冲突排在哪。
- app_accounts.dart：应用账号跟着教务走、按需核对、核对后重登（类上方）；跟着走的接线在 main.dart 的 watchAppAccounts。
- 自动同步与三方合并的决定在 domain/auto_sync.dart。
