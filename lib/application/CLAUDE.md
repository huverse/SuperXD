# application 应用编排

定位：跨领域的编排，由组合根创建（造法在 app_services.dart）并注入页面。分层表允许依赖 domain 与 gateway，现在只用 domain 端口（CampusGateway、提醒、小组件与更新端口）。本层决定做什么、什么时候做，具体能力交给 device、local 的实现。

# 文件职责

- campus_sync.dart：显式同步的唯一编排入口 CampusSync。
  - 先刷新学期列表，再按所选学年依次处理：先同步全部学期的课表，再逐学期同步作息和成绩；每个实例内按顺序逐项请求。
  - 同步流水线（[人工决策] 在 CampusSyncStep 上）：每类数据一个步骤（ScheduleSyncStep、BellsSyncStep、GradesSyncStep，各自只用对应的窄端口），登记在 campusSyncSteps，登记顺序即执行顺序、leading 的先做完全部学期；CampusSync 只管学期、待办、离开与该停就停，步骤返回这一项做没做完（没做完的留在未处理里）；加一类数据只加一个步骤。
  - 页面离开、会话失效或教务限流时，在下一检查点停止；报告带出已完成项、停下前已发生的失败与未处理项。
  - 学年与数据项的选择、进度口径、未提交不报已同步，见文件内人工决策。
  - 课表和本地改过的版本冲突时交给 resolveSchedule 决定 ScheduleResolution（KeepLocal、TakeEdu、MergeEdu），settle 落库，自动同步与打扰时机共用。
  - 同步记录（人工决策见 domain/sync_record.dart）：每轮做完（含中途停下）记一条，yields（自动同步）记成自动、其余手动；同步完了、没记下变化的课表与成绩记成和上次一样（same）；课表每学期同步前读本机那一版，落了新版本才和教务这份比（scheduleSyncChange，本机原来没有记成第一次，before 留给撤回），冲突时按选择记落库前后的差别或「等你来选」；成绩同步前读本机缓存比出新出与改了分数的（gradeSyncChange，cached 为假记成第一次）；settle 带 record 时（打扰时机、学业页的待处理里选完）另记一条；记不成只记日志。报告 CampusSyncReport.record 是这一轮的记录。activeRuns 是本进程里正在跑的轮数，自动同步据此让路；让路的那轮（yields）还没收尾时，手动同步先等它停下再发请求，不撞上它在途的请求。
- auto_sync.dart：自动同步的编排 AutoSync（设备级，经账号门面跟着当前账号，人工决策见 domain/auto_sync.dart）。
  - runIfDue：到期（autoSyncDue）且没有别的同步在跑才同步一轮，范围取设置里的学年与内容（当前学年按本机的当前学期取）；同一个账号同一时刻只跑一轮，有人手动同步就在下一检查点让路。
    - 开跑时记下账号代次（组合根注入 generation）：中途换了账号就在下一检查点停下，结果不记、暂存不读（门面跟着当前账号走，不变量 1）；换账号后再按新账号看一次到没到期。
    - keepGoing 由组合根给（后台任务的时限、安卓系统叫停、前台那份已经起来），返回假就在下一检查点停下。
  - 有值得通知的变化（syncRecordNotice）时经组合根注入的 notices（device 的 SyncNotifications）发系统通知，出错只记日志；打扰时机里处理暂存的那份（settle）另记一条同步记录。
  - 冲突不覆盖：教务这份和上次同步的一样（只是自己改过）就悄悄保留本地、以后不问；教务确有新改动才留到打扰时机问（held）。作息来源一律不自动改。
  - syncing：这一份引擎正在同步（设置弹窗据此写正在自动同步）。上次开跑的时刻 lastAttemptAt 只用来算到期，页面上的「上次自动同步」读同步记录。
  - 上次结果按报告记：登录过期记 paused（不转登录页、本机会话留着，见 keepSessionDuring；后台不到期，用户打开应用时到了间隔试一次，重新登录才清掉）、没连上网记 network（15 分钟后可再试）、限流记 limited、其余失败记 failed 并写明哪一项；让路或被叫停没做完的一轮不算成功也不算失败，上次结果照旧。
  - accountChanged 与 save 按设置排好或撤掉系统后台任务（端口 BackgroundSyncScheduler），系统接口出错只记日志。settle 处理打扰时机里选的结果；stillHeld 在弹之前从当前账号的本机库重读暂存的那份（手动同步过、换过账号就没了）。accountChanged 先清掉上一个账号的设置与暂存。
- campus_reminders.dart：课前提醒对账 CampusReminders。读本机的当前学期、提醒设置、课表与作息，展开未来 14 天的课程实例，整体替换系统里的提醒；没有当前学期（含退出登录）、未开启或没有通知权限时撤销本应用的全部课前提醒。开了状态栏胶囊且系统有实时更新时提醒发成实时更新（OPPO 流体云），[人工决策] 在类上方。
- campus_widgets.dart：桌面课表小组件的快照 CampusWidgets。读本机的当前学期、课表与作息，展开今天起 7 天的课程实例交给小组件端口；退出登录时发布空快照，缺开学日或作息时如实提示。
- campus_timetable.dart：campusTimetableToday 读本机的当前学期、课表与作息，展开今天的课程实例（CampusTimetable），由组合根经百宝箱运行时交给学习通签到推断正在上的课；未登录、没有学期、缺开学日或作息时给原因。只读本地、从不联网。
- app_updates.dart：应用内更新编排 AppUpdates，设备级，切换账号不重建。
  - 自动检查每个校园日一次（appUpdateCheckDue，按业务日界），待必须更新时每次启动都查；手动检查不受限、不认跳过。自动检查时可选更新不在这一批（组合根注入的 inBatch，即 Rollouts.inUpdateBatch）就当没有，手动检查与必须更新不受批次限制。
  - 点更新才下载（缓存里已有且 SHA-256 对得上就不再下），核对 SHA-256、包名、版本号与签名证书，对不上就删包报原因；没有「安装未知应用」授权时引导开启，下载在后台完成时等回前台再拉起系统安装。
  - 端口都在 domain/app_update.dart，实现在 device 与 local（见各自 CLAUDE.md）；规则与弹窗的人工决策见 app_update.dart 与 page/app_update_dialog.dart。

- developer_notes.dart：开发者的话的编排 DeveloperNotes（设备级）：自动拉取间隔至少 developerNoteRefreshGap（一小时，下拉刷新不受限；换了版本一打开就重拉，旧版本拉的信重拉之前不弹）、同一时刻只拉一次、失败照旧显示上次拉到的；已读与弹过记在本机（弹出的信被用户关掉时，当时所有的信都记成弹过、只有这封记成读过；11-18 人工决策在 app_moments.dart 与 local/developer_note_memory.dart）。人工决策见 domain/developer_note.dart。
- festivals.dart：节日的编排 Festivals（设备级）：今天该播哪一次（在节日里、没播过）、启动与回到前台记今天打开过（只留近 30 天）、抽签（有抽奖、配了中转、登录着应用账号、结果没定时才抽，同一时刻只发一次；当前应用账号由组合根注入；连不上或没登录不记，中转说账号已不在时调 accountGone 让应用账号马上核一次；账号建立不满规定天数的不记，到 eligibleAt 之前不再为这个账号抽，只记在内存里）、抽签时按组合根注入的 levelsOn 带上要不要按等级加权（仅本机为假）；online 为假（仅本机）时不抽签、不领、不问状态、不提示去登录、needsSignIn（有抽奖但没登录，组合根在动画放完时提示去登录）、抽中的奖品（没揭晓的等打扰时机揭晓，节日结束后 3 天删）。refresh 是同意协议与政策后、每次回到前台、登录了应用账号时由组合根调的：补抽播过动画还没抽的。11-16 起另给开发者的话里的红包用：status 问一个活动能不能领、claim 领（同一活动同一时刻只发一次，领到的记进奖品、留到活动结束后 3 天，没资格与天数不够不记）、prizeOf 取这个活动的奖品。人工决策见 domain/festival.dart 与 domain/developer_note.dart 的附件。
- app_accounts.dart：应用账号的编排 AppAccounts（设备级，人工决策见 domain/app_account.dart）：这台设备一个应用账号，与教务各管各的（切换、退出教务都不影响，没登录教务也能登录）。load 在启动时读本机记录，先清掉 11-15 以前的旧密钥并把它们交给 onDeleted（清那些账号的本机私信，老账号全部重新注册），本机记录读不出时当没登录、照样读完；register 在这里生成恢复码、成功后交给页面显示一次；login；recover 先把输入的恢复码规范写法（不像恢复码的不联网），成功换新恢复码；changePassword、renewRecoveryCode 要登录着；startJoin、pollJoin 给新设备扫码登录（轮询连不上照旧等、不占 busy），cancelJoin 在离开出示页与刷新时作废票据（不等、出错只记日志），inspectJoin、approveJoin 给登录着的设备先看请求方再批准；操作中中转说这台设备不在账号里或账号已注销就马上核一次；signOut、deleteAccount 由应用账号页发起（注销成功后调 onDeleted）；check 在同意协议与政策后、回到前台时由组合根调，登录着且隔 checkGap（一天）才联网，不在账号里了（被顶掉、重设踢下线）退回未登录，账号已注销的另交给 onDeleted 清本机那个账号的私信（这一问在路上时换成了别的账号，当前账号不动，但被注销的那个照样交出去清，11-28 复核 F03）；force 为真时不等间隔。current 是当前的应用账号 AppAccountRef（挑战、节日抽奖等只认它），accountId 是它的账号号（灰度与分批更新分桶用），username 给页面显示。
- account_diagnostics.dart：记在应用账号下的诊断包 AccountDiagnostics（设备级，人工决策见 domain/diagnostic_upload.dart）：本身实现 DiagnosticUploader，包住 device 的上传，传完登录着当前应用账号就凭回执里的一次性口令认领，回执标上 claimed；认领没成只记日志、包照旧匿名留着。list、delete 给应用账号页「我上传的诊断包」；中转说账号已不在时调 accountGone 让应用账号马上核一次。
- challenges.dart：挑战与积分的编排 Challenges（设备级，实现 domain 的 ChallengeHub，人工决策见 playground/challenge/challenge_rules.dart）：跟着当前的应用账号走（AppAccounts.current，不再要求登录教务），没登录应用账号不联网直接报未登录；中转说应用账号不在了（别处注销、被清理）就让 AppAccounts.check(force: true) 马上核一次，本机退回未登录；当前应用账号变了（登录、退出、直接换成另一个账号）发 changes。 deleteData 不在 ChallengeHub 里，只给 leisure.dart 删服务器上的积分、挑战与解锁。
- unlocks.dart：解锁的编排 Unlocks（设备级，实现 domain 的 UnlockAccess，规则见服务端 src/modules/unlock/unlock_rules.ts）：清单来自 Rollouts.config 的 unlocks，本机判定下架锁着、公开开着（没登录也开），其余看服务器给的这个账号能用哪些（换了应用账号旧状态不作数）；组合根在同意协议与政策后调 start 才联网，之后拉到新配置、切换应用账号时重问，回到前台隔 refreshGap（一小时）再问，积分页打开与买了直接更新；清单里没有要账号才开的项或没登录时不联网；中转说应用账号不在了就让 AppAccounts 马上核一次。 accountOn 为假（仅本机）时只认公开与下架、不联网，联网偏好变了或删了数据组合根调 reconsider（旧状态作废、开着就重问）。
- passes.dart：积分时长券的编排 Passes（设备级，实现 domain 的 PassAccess，人工决策见 domain/pass.dart；预接好、不启用）：清单与当前应用账号买到哪天都记在本机（local 的 pass.json），离线照本机记的判定；refresh 由电影院打开时调（不挡页面），联网时拉清单（免签名），登录着应用账号再问自己的券，同一个应用账号隔 passRefreshGap 才真去拉（force 不等）；仅本机时不联网、不能买；当前应用账号与「账号已不在」的核对由组合根以函数注入。
- rollouts.dart：灰度的编排 Rollouts（设备级，人工决策见 domain/rollout.dart；同时实现 domain 的 FeatureGate，changes 跟着 notifyListeners 发，给百宝箱问开关）：本机判定，主体是应用账号号（组合根注入，没登录用本机随机编号）；enabled 判功能开关（被点名且没到期的直接开；配置里有就先看条件（平台、渠道、版本号由组合根注入），再按比例；没配用调用方给的默认值），功能只经 isOn 与 param 问登记过的 FeatureFlag；refresh 时登录着应用账号同一时机经组合根注入的 targets 问一次点名（问不到照旧用记着的，问到空列表即全撤销）；inUpdateBatch 判分批更新（健康回报自动暂停了这一版就不在批次里；配置里同名开关覆盖清单的放量表：暂停、直接全量、整版关停）；refresh 在同意协议与政策后、回到前台时由组合根调，两次至少隔 checkGap（30 秒），配置与点名都带上次的版本号核对（没变中转回 304），失败照旧用上次的，登录着应用账号时经组合根注入的 level 取积分等级（至少隔 refreshGap 一小时，取不到照旧用记着的）；11-20 起听组合根给的 RolloutSignals：中转回复头里的配置或点名版本和本机记的不一样就马上重新取，同一个版本号一次运行只触发一次（人工决策见 domain/rollout.dart）；判定按等级加权，只因等级进的批次记进本机、降级不踢出，放量 0 仍全关；没配中转时不联网。 levelsOn 为假（仅本机）时不取等级、不问点名、按 Lv0 判定（已因等级进的照旧）；forgetLevel 在删了游乐场与积分的数据时把记着的等级归零。
- app_health.dart：分批更新的健康回报与新版本反馈 AppHealth（设备级，人工决策见 domain/app_health.dart）：按校园日加版本各记一项（11-27 起，升级当天新旧版本各报一份）：markActive 记今天打开过与版本（换版本从那天起算反馈窗口），markFatal 把出错那天这个版本记成有致命错误（组合根接上错误出口），markExit 按系统记下的时刻把上次异常结束记到那时在用的版本（组合根接上上次退出原因），markLaunch 记一次启动用时（组合根在首帧上屏时交来）、countFrames 在内存里累加帧数与慢帧数（组合根的帧耗时回调交来）、flushFrames 切到后台与跨过日界时写进那天，reportDue 发过完且没发过的几天（同一时刻只发一轮，连不上留着、拒收记成发过），feedbackOpen 与 sendFeedback 给关于页；没配中转时什么都不发、不给入口。
- leisure.dart：游乐场与积分的删除数据 Leisure（设备级，人工决策见 domain/leisure.dart）：deleteData 登录着应用账号且联网时先删服务器上的（组合根注入 deleteRemote，失败原样抛出、本机不动），再清本机（注入 clearLocal：游乐场记录与记着的等级），返回服务器上的有没有一起删。11-16 起开关并进联网偏好。不认识游乐场、挑战与灰度。
- network_preference.dart：联网偏好 NetworkPreference（设备级，人工决策见 domain/network_policy.dart 的 11-16 22:24:59 那条）：本身就是联网策略（组合根交给 AppHooks），mode、online、setMode（变了才写、通知一次）；组合根跟着它让私信停下或接着用、解锁重新判定，节日、灰度、解锁与诊断包认领读它的 online。
- quick_nav.dart：今天页侧栏的常用与最近 QuickNav（设备级，规则见 domain/quick_nav.dart）：visit 记最近（已在最前不写；热路径上不等写盘，写不成只记日志），pin 存编辑页排好的常用（先通知再等写盘）；组合根在进了入口目录里的页面时调 visit。
- app_moments.dart：打扰时机 AppMoments（设备级）：一次只出现一件，先后是节日动画、没揭晓的奖品、自动同步留下的课表冲突、新信；决定节日动画、新信这类不是用户要的内容什么时候出现。业务条件在这里：每次回到前台最多一件、从快捷入口进来的那次前台不出现、上下课安静期里不出现（安静期结束时提醒组合根再看一眼）、有强制更新还没装时不弹信、信在用户关掉时（closed）才记成弹过；界面条件在组合根 app_shell.dart 的 _promptMoment。next 只看不记，真的弹出来了再 begin。人工决策在类上方。

# 关键规则

- 课前提醒与小组件只读本地、从不联网；对账时机由 app_lifecycle.dart 的 watchLocalSchedule 决定（启动恢复会话后、回到前台、切换账号或退出、本机课表相关写入后 AccountAccess.scheduleChanges），1 秒防抖。小组件配色由 app_lifecycle.dart 的 watchWidgetTheme 跟随显示设置单独下发。
- 同步遇到 SESSION_EXPIRED 立即停止并交给 onSessionExpired；遇到 RATE_LIMITED 本轮立即停止，不自动重试、不转登录。
- 只经 domain 端口做事，不直接访问 SQLite、教务客户端或系统 API。

# 测试

- campus_sync_test.dart、sync_ui_test.dart、transition_sync_test.dart（同步编排与同步界面）；auto_sync_test.dart（到期规则、账号库、自动同步编排与打扰时机的先后）；sync_merge_test.dart（合并页、手动同步流程、打扰时机弹窗、自动同步设置）
- reminder_test.dart、home_widget_test.dart（课前提醒、小组件）；campus_timetable_test.dart（本应用课表今天的课）
- app_update_test.dart、app_update_ui_test.dart（应用更新，替身在 app_update_fakes.dart）
- app_account_test.dart（应用账号的中转客户端、编排与页面）；challenge_test.dart（挑战的编排与中转客户端，页面部分见 lib/playground/CLAUDE.md）
- app_health_test.dart（健康回报与反馈的规则、性能档位的分档与中位、原始数的读写、本机记录、编排（启动与帧数记进当天、跨日界）、中转客户端、自动暂停只少提示、关于页入口与弹窗、异常退出交出时刻）
- rollout_test.dart（灰度编排、分批更新按批次、积分等级加权与降级不踢出、仅本机按 Lv0）
- leisure_test.dart（游乐场与积分的删除数据的先后与游乐场记录清空；界面在 app_account_test.dart）；network_mode_test.dart（联网偏好的本机记录、偏好与策略）
- pass_test.dart（时长券：清单与券的外部输入边界、本机记录、编排的判定与仅本机、中转客户端的清单请求；服务端在 server/test/pass.e2e.test.ts）
- unlock_test.dart（解锁编排：下架锁着、公开开着、同意前与没登录不联网、仅本机只认公开与下架、换账号、买了更新、账号不在了马上核；中转客户端；游乐场锁着的卡、百宝箱藏起锁着的工具、积分页列能买的；路由拦住锁着的入口在 account_lifecycle_test.dart）
- developer_notes_test.dart（开发者的话的拉取、已读与打扰时机）；festival_test.dart（节日编排、抽签与打扰时机的先后）；diagnostic_upload_test.dart（诊断包认领、列出与删除的编排与中转客户端）；account_lifecycle_test.dart（「我的」页入口与小圆点、新信在什么界面条件下弹）

# 人工决策检索

- 命令：grep -rn 人工决策- lib/application
- campus_sync.dart：学年与数据项统一范围、进度只报已有阶段、未提交不报已同步、离开前的失败照常写入报告、限流立即停止。
- campus_reminders.dart：状态栏胶囊（流体云）的接入方式、显示时段与胶囊内容。
- app_moments.dart：打扰时机的业务条件、课表冲突排在哪。
- 应用账号的决定（自己的账号体系、与教务各管各的）在 domain/app_account.dart；组合根接线在 app_lifecycle.dart 的 watchAppAccounts。
- 自动同步与三方合并的决定在 domain/auto_sync.dart。
