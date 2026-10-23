# page 页面

定位：Flutter 页面与页面级组件。
- 依赖范围：domain（端口与类型）、application（同步编排、应用更新）、social（私信服务）、theme（视觉组件）和 app_session.dart。gateway 只用 account_access.dart，local 只用 display_settings.dart、developer_settings.dart 与 diagnostic_log.dart（后两个只给开发者选项与关于页）。
- 页面只调用 CampusGateway、AccountAccess、SocialService 和 AppUpdates，不直接读写数据库，也不直接调用教务客户端或中转服务。页面不依赖百宝箱，打开好友分享的视频经路由注入的 VideoOpener。

# 文件职责

- 壳层与导航：
  - shell_page.dart：底栏壳 ShellPage（今天、服务、消息、我的四个分支；在别的分支按返回先回今天，[人工决策] 在文件内）与可拖动底栏 DragNavigationBar：悬浮在安全区之上，内容延伸到玻璃下方，底栏占位作为各页的底部安全区；拖动时的透镜是栏玻璃的兄弟层、不被栏裁剪；「消息」带私信未读角标。
  - animated_branches.dart：分支切换 AnimatedBranches，保留每个分支的 Navigator；进出两页整屏并排平移，不淡入淡出（页内玻璃在半透明图层下取不到背景）。
  - section_pages.dart：服务页（课表、成绩、百宝箱入口）、我的页（头像卡读当前会话，只写姓名，姓名未知时显示学号；学号与班级在账号页）与底栏根页的大标题顶栏 SectionTitleBar。
- 私信（只有分享卡片，没有文字聊天）：
  - message_page.dart：消息页，只放私信（还没有通知来源，不放空的「通知」分段，[人工决策] 在文件头）；未开启时是开启卡片（含数据处理说明与隐私政策），开启后是添加好友与好友列表（按最近活动排序，下拉刷新并核对好友，增删好友时那一行原地展开、收起；时间在名字一行右端、未读角标在预览一行右端，大字号下各自长高不溢出）。
  - friend_add_page.dart：添加好友：出示自己的二维码（浅色画，保证可扫）与倒计时，离开即作废；出示时本页屏幕亮度调到最高、离开恢复（screen_brightness，只改本应用窗口，[人工决策] 在 initState）；「扫一扫」扫对方的码。扫码函数可注入（InviteScanner）。
  - qr_scan_page.dart：通用扫码页 QrScanPage：相机只认 QR、识别在本机，也可从相册识别；内容交给调用方的 accept 判断，认下就返回原文，不打开任何链接。好友二维码与课堂签到二维码共用。
  - conversation_page.dart：会话页：卡片列表最新在下，自己的卡片原地显示发送中、失败与重发；对方的卡片贴左、自己的贴右、最宽 82%；卡片⋯可重发或删除（仅本机）；两处 [人工决策] 都在 _item；底部分享课表与界面；对方解除好友后改为提示。
  - share_card_view.dart：卡片渲染：课表（查看与对比，收到的可导入）、界面配置（预览、套用）、视频（打开）、未知类型（提示更新应用）。
  - friend_schedule_page.dart：好友课表与「共同空闲」（读本机同学期课表按日期对齐）；没有同学期课表或缺开学日时如实说明；顶栏可导入到自己的课表。
  - schedule_import.dart：好友课表导入 importSharedSchedule：先读好本机课表再打开导入页（推入根导航器），顶部分段「逐项合并 / 整份替换」：逐项合并按 domain 的 planScheduleMerge 列出有改动的课（每处差异一行、原来的划掉，整门可半选）、TA有你没有的课、你有TA没有的课（勾上会删掉），默认只勾有同一个教学班的那几门课的改动；应用按钮原地转圈，与其余课重叠时先确认；都存成当前账号的新版本、可在历史版本恢复，开学日与作息不动，成功的提示条回到发起页显示；本机没有那个学期时说明原因、不联网（[人工决策] 在文件内）。会话卡片与好友课表页共用。
  - share_target_sheet.dart：分享弹层 showShareSheet：多选好友后逐个发送，每行原地显示状态，失败的可重发；课表页、界面页、百宝箱结果页共用。
  - social_dialogs.dart：错误码文案 socialErrorText、列表时间 socialShortTime、单行输入弹窗 showSocialTextInput。
- 今天：
  - today_page.dart：今天页 TodayPage：读当前学期的课表与作息按日浏览；同步按钮走 chooseSyncSelection → CampusSync.run → showCampusSyncReport，没同步时正中给「同步课表」；课表页的「去同步」经 TodaySyncRequest 回到这里打开同步范围（组合根创建，[人工决策] 在类上）；含作息来源确认与缺开学日引导；同步中离开时结果暂存、回来再提示。顶部「此刻」卡（_ClassNow）显示上课中或下一节，课上完或没课时大字写状态、下面一行预告下一节（以后没课的日子也预告，不放右侧大号时刻，免得像课程卡），没课只在这张卡里说；到点换状态平滑过渡、开课前 15 分钟强调倒计时、5 分钟内按秒倒数、倒计时换数字时滚动、上课中此刻点定时漾开、整卡可点（[人工决策] 在 _ClassNow 上方）；看别的日子时底栏上方居中显示回「今天」胶囊（[人工决策] 见 _layout）；单击有课卡弹只读详情（_openCourse）。
  - today_day_navigation.dart：上下拖动切日的手势 TodayDayNavigation（阈值 64、上限 120）。
  - today_date_transition.dart：切日时日期与正文按同一进度纵向交接 TodayDateTransition。
  - course_cards.dart：有课卡的只读详情 showCourseDetail（今天页与课表页共用，课表页带「编辑课程」）；当日节次卡片 CourseDayCards：有课卡（课名、教室行 CoursePlace、节次与教师；时刻列开始前上课时刻大、开始后下课时刻大）与空档（虚线空位框 _EmptySlot，高度随时长对数加高），课表页长按展开（读屏整卡一句、长按提示展开详情）；今天页单击回调 onOpen（按下变暗、读屏整卡一句），revealNow 打开时把正在上或下一节滚进可见区；今天的课按 classMoment 分三态，时长格式 classDuration。整天没课时有顶部卡片（今天页）就不在中间重复，没有才居中写「这天没课」。人工决策见 _CourseCardBody 与 revealNow。
  - live_clock.dart：全局分钟时钟 LiveClock，整分钟唤醒、后台暂停；测试要拨时间时用 LiveClock.fixed（不挂计时器，否则真实时间到整分会盖掉拨好的时间）。liveOf 说明是否真实时钟，要秒级刷新的界面只在真实时钟下自己计时。
  - date_rail.dart：日期横条 DateRail（读屏每项一句并可点选）。
- 课表：
  - schedule_page.dart：课表页 SchedulePage：天、学期、学年三种范围，可设开学日；标题旁写第几周，学期视图打开即展开所看日期的月与周、本周写「本周」（[人工决策] 在 _drilled）；单击有课卡看只读详情、长按展开；无课时段可新增课程或安排已有课程；没同步的学期给「去同步」（onSync）；顶栏只留「今天」胶囊、「管理课程」与⋯（开学日、课前提醒、导出到日历、分享给好友，后两项按注入的服务显示）。
  - calendar_export.dart：导出到日历 exportTermCalendar：当前所看学期写成 .ics 交给日历应用；缺开学日或作息时说明原因不导出，找不到的节次不猜时刻；文件只放缓存 calendar_export 文件夹（每次先清空），经原生 CalendarExporter.kt 交出。交付函数可注入（openCalendar）。
  - reminder_dialog.dart：课前提醒设置 showReminderSettings：开关、提前时间与状态栏胶囊按学期保存（系统有实时更新才给胶囊开关），状态行如实显示安排结果，需要处理的给「开启通知」「准时提醒」「开启胶囊」。
  - schedule_calendar.dart：课表页月份轨道与周次轨道的纯函数。
  - schedule_editor_page.dart：课程管理 ScheduleEditorPage：同名的教学班合成一门显示（一位老师写在课名下，几位写在各自时段后）；新增、编辑、删除（可撤销）、清空、建空课表与历史版本入口；点卡片编辑，⋯里只有删除（[人工决策] 在课程卡列表上方）。
  - course_editor_page.dart：课程编辑 CourseEditorPage：一门课（同名的几个教学班）一起编辑，课名与学分对整门生效，老师和地点写在每个时段上，保存时按老师分回教学班；时段卡点按直接改、范围在弹窗顶部选，复制与移除在⋯里（[人工决策] 在 _SlotDialog）；周次是等宽网格、快捷选周只亮正好匹配的一项（[人工决策] 在 _weekGrid）。
  - schedule_history_page.dart：课表历史版本 ScheduleHistoryPage：按日期分组的时间线，图标分教务同步、我的修改、恢复，可筛「全部 / 我的修改 / 教务同步」，按序号游标分页；点开写恢复后和现在比会加回、会删掉、会改回，恢复带乐观锁（[人工决策] 在文件内）。
  - term_start_dialog.dart：开学日设置弹窗 editTermStart，保存成功只出提示条写第1周从哪天开始，失败才弹窗。
- 成绩：
  - grades_page.dart：成绩页 GradesPage：学年与学期汇总、有效成绩与原始成绩，可筛选、排序、搜索；本页只同步成绩；视图切换淡出淡入（旧内容淡出后才换数据）。筛选是一行「搜索框 + 筛选按钮」，类型、范围、排序在弹层里点了就生效；成绩按行列在一张分组卡里、分数在右，不及格警示色并写明（[人工决策] 在 _filterLabel 上方与 domain/grades.dart 的 gradeFailing）；教务汇总绩点大字（_summaryFigures，缺的那一项写「—」），教务明确这学期没有成绩时只画空状态卡（_emptyGrades）、不画汇总；详情按内容高（_details）；人工决策在方法上。
- 同步：
  - sync_selection_dialog.dart：同步范围选择 chooseSyncSelection：学年与内容都可多选，默认读本地学期列表，点刷新才联网。
  - campus_sync_dialogs.dart：同步结果弹窗 showCampusSyncReport：结果与未处理项，可重新登录或重新同步；教务限流停下时只说明约 1 分钟后再同步，不给立即重新同步。
- 账号与设置：
  - login_page.dart：登录页 LoginPage，也用于切换账号：验证码、记住账号确认、百宝箱、关于（进同一个关于页，未登录也能开开发者模式、检查更新，[人工决策] 在按钮处）与法务入口；同意行勾选框读屏读整句，点「我已阅读并同意」也能勾选；登录按钮常亮，没填或没勾同意时原地说明，接系统自动填充（[人工决策] 在文件内）。
  - account_dialogs.dart：旧版本数据导入确认 showLegacyImport 与登录后自动提示的 LegacyImportGate；教务验证码弹窗 LoginCaptchaDialog；开启记住账号的输密码弹窗 askRememberPassword。
  - account_page.dart：账号页 AccountPage（账号卡姓名下写学号 · 班级，只在这里写；AccountTitle 我的页共用、只传姓名）：记住账号（关闭即删凭据；重新开启要输密码、后台登录核对成功才保存，不换代次）、切换账号、导入旧版本数据（本机有旧数据才显示）；退出登录单独一组放最底。
  - appearance_page.dart：界面设置 AppearancePage：字号、配色、字体、深浅色、玻璃效果与背景（自定义图片经系统照片选择器，选图函数可注入）；可分享给好友（不含壁纸图片）。字体预览用 assets/font_previews 里预先画好的图（tool/font_previews.dart 生成），不为预览加载没在用的字体。滑杆拖动中只预览、松手保存，系统取消与读屏增减停手 300ms 补存，离开页面时存掉没存的预览。选项点了就生效，落库在 DisplaySettings 的保存锁里排队，保存时不禁用页面上的其他选项。改字号、换字体时整页重新排版，点的那一行经 theme 的 CampusAnchoredScrollController 停在手指下（字号另有连续过渡，见 local 的 CampusTextScale）。玻璃限档时点「完整」先解除限档。
  - image_copy_pick.dart：通用取图 pickImageCopy 与多选 pickImagesCopy，返回副本路径与 discard；只删插件这次新留在缓存里的副本。壁纸、相册识别二维码共用，并经组合根注入百宝箱。
  - developer_page.dart：开发者选项 DeveloperPage（开关、日志导出与清除、复制诊断摘要、连电脑的 adb 命令、性能浮层、运行环境；关闭开发者模式删开发者模式日志）、日志查看 DeveloperLogPage（全部或错误、错误按种类合并写出现几次、搜索、点开看全文与复制）与悬浮开发者工具 DeveloperOverlay（开发者模式下浮在所有页面上、可拖动贴边，点开可标记当前页面与一句说明、查看日志、导出、进开发者选项；自带一层 Overlay，开关时不改页面的父级结构，性能浮层也画在这层里、不用 MaterialApp 的开关（那个会给整页加一层 Stack、换父级重建），[人工决策] 在类上）。
  - about_page.dart：关于页 AboutPage（连点版本号 7 次开启开发者模式，开着时多一项开发者选项）：应用图标（assets/app_icon.png，测试期临时图，见开源许可第五节）、版本、检查更新（传入 AppUpdates 时才有）、用户协议、隐私政策、开源许可、源代码与反馈问题；版本信息与打开链接可注入。
  - app_update_dialog.dart：更新弹窗 showAppUpdateDialog：可选更新给更新、稍后、跳过这个版本，点更新才下载，下载、核对、等授权、安装都在弹窗里原地切换；必须更新时关不掉（人工决策见文件内）。
  - legal_page.dart：用户协议与隐私政策 LegalPage（/legal/service、/legal/privacy），顶部显示更新日期 legalUpdated；正文经 theme 的 CampusProse 按行排版。隐私政策先摘要、再按功能分节，末尾附第三方 SDK 与服务、系统权限、保存期限三份清单（[人工决策] 在文件头）；改动数据处理、新增 SDK 或权限、改上限时同步改对应一节与清单并更新日期。首次打开（含没在弹窗里同意过的老用户）由组合根弹 askLegalConsent 征得同意，不同意先二次确认再退出应用（[人工决策] 在函数上）；同意过的，有实质变化时 legalRevision 加一并改写 legalChanges，打开后弹一次 showLegalUpdateNotice（只有「知道了」才算看过）。
  - licenses_page.dart：全部依赖许可 CampusLicensesPage 与应用署名 GalaxyousAttribution。
  - third_party_page.dart：开源许可页 ThirdPartyPage，读 assets/third_party_notices.txt。

# 关键规则

- 异步结果写界面前先检查 mounted，涉及账号的再检查 isAccountCurrent；遇到 SESSION_EXPIRED 交给 onSessionExpired。
- 分支页用 TickerMode 判断是否可见；今天分支重新可见时只刷新本地数据、不联网，并展示暂存的同步报告。
- 页面平时只读本地（read 系列方法），联网只由用户显式触发：同步统一经 CampusSync，成绩页只同步成绩，同步范围弹窗里的刷新学期也要用户点。例外：应用更新的自动检查由组合根发起；私信由 SocialService 的前台长轮询送达，页面不自己定时拉取，SocialService.refresh 会同步通知监听者，不能在构建期间调用。
- 好友分享的课表可查看、对比，写进自己的课表只经 schedule_import.dart（用户确认后存成新版本）；套用界面配置后提示条可撤销；视频交给百宝箱重新解析，首次使用来源仍由本人同意。
- 今天页只读课表，编辑入口只在课表页；课表页的有课卡与空档只在长按时展开，今天页单击有课卡看详情。
- 弹窗统一走 showCampusDialog 系列：确认用 showCampusConfirm，提示用 showCampusNotice，耗时操作用 showCampusWaiting。setState 回调不得返回 Future。
- 切日、底栏拖动等手势：拖动中只预览不提交，正常松手和系统取消分别处理；方向或手势类改动先对照 today_page.dart、today_day_navigation.dart 的人工决策，以及记忆里被否决的视觉方案。
- 「甲 · 乙」式说明行一律用 theme 的 DotSeparatedText，避免窄处与大字号下折出孤字。
- 面向用户的节次、学分与时刻只用 domain 的 periodLabel、creditLabel 与 formatCampusRelative，页面不自己拼「第x–x节」或带秒的时间。
- schedule_calendar.dart 的 semesterDays、weekDates 只有测试在用，删除前先改测试。

# 测试

- 今天与课表：today_navigation_test.dart、today_date_transition_test.dart、schedule_experience_test.dart、schedule_editor_ui_test.dart、schedule_calendar_test.dart、course_clock_performance_test.dart、calendar_export_test.dart。
- 成绩与同步：grades_ui_test.dart、sync_ui_test.dart。
- 壳层与表单：navigation_drag_test.dart、shell_layout_test.dart、form_spacing_test.dart（支撑 form_layout_support.dart）。
- 设置与关于：appearance_settings_test.dart、wallpaper_test.dart、legal_page_test.dart、about_page_test.dart、app_update_ui_test.dart。
- 私信页面：social_ui_test.dart（含好友课表导入的整份替换与逐项合并）、share_card_test.dart；合并规则在 schedule_merge_test.dart。
- 开发者模式：developer_mode_test.dart。
- 页面测试的合成数据网关是 fixture_campus_gateway.dart（读 assets/fixtures）。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/page
- 本目录的标记集中在：切日方向与交接、回今天胶囊、底栏拖动与安全区、课程卡长按、无课时段新增、管理课程的课程卡与时段弹窗、历史版本时间线、好友课表导入、成绩同步范围与学年汇总、旧库导入确认、法务说明、我的页与账号页和关于页的归类、同步中止提示、壁纸滑杆、课表顶栏精简、成绩页切换淡出淡入、成绩汇总缺值写法、会话卡片⋯与排法、应用更新弹窗。
