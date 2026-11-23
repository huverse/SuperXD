# page 页面

定位：Flutter 页面与页面级组件。
- 依赖范围：domain（端口与类型）、application（同步编排、自动同步、应用更新）、social（私信服务）、theme（视觉组件）和 app_session.dart。gateway 只用 account_access.dart，local 只用 display_settings.dart、developer_settings.dart 与 diagnostic_log.dart（后两个只给开发者选项与关于页）。
- 页面只调用 CampusGateway、AccountAccess、SocialService、AppUpdates 和 AutoSync，不直接读写数据库，也不直接调用教务客户端或中转服务。页面不依赖百宝箱，打开好友分享的视频经路由注入的 VideoOpener。

# 文件职责

- 壳层与导航：
  - shell_page.dart：底栏壳 ShellPage（今天、服务、消息、我的四个分支；在别的分支按返回先回今天，[人工决策] 在文件内）与可拖动底栏 DragNavigationBar：悬浮在安全区之上，内容延伸到玻璃下方，底栏占位作为各页的底部安全区；拖动时的透镜是栏玻璃的兄弟层、不被栏裁剪；「消息」带私信未读角标，「我的」在有没读的开发者的话时带一个不计数的小圆点（dots）。iOS 26 起换成挂在 Flutter 视图上的系统底栏 NativeTabBar（theme/native_glass.dart；iOS 16–18 用同安卓的自绘底栏，只是再点当前项同 iOS，[人工决策] 见 campusSystemTabBar），角标与小圆点照旧，拖动与悬浮由系统做，内容按系统报来的总高留位置，开屏走完（revealed）才出现；两端底栏都是提示条的锚点（theme 的 CampusToastAnchor），提示条停在底栏上方；再点当前项回到这一栏首页、已在首页时滚回顶部（[人工决策] 在 onSelected）。给了 drawer 时整个壳包进侧栏 theme 的 CampusSideDrawer（只在今天这一栏能拉出，系统底栏跟着侧栏的位移走）。
  - animated_branches.dart：分支切换 AnimatedBranches，保留每个分支的 Navigator；进出两页整屏并排平移，不淡入淡出（页内玻璃在半透明图层下取不到背景）。iOS 上直接切换、不滑动（[人工决策] 在 didUpdateWidget）。
  - section_pages.dart：服务页（学业、百宝箱、游乐场入口，[人工决策] 在列表上方；游乐场一直列着）、我的页（11-19 起只有头像卡、应用账号、界面、关于，[人工决策] 在那一组上：配了中转时「应用账号」一行 AppAccountRow 写用户名或未登录、有没读的开发者的话时行尾一个小圆点，点了推入应用账号页，开发者的话与我的红包都在那页；头像卡读当前会话，只写姓名，姓名未知时显示学号；学号与班级在账号页）与底栏根页的大标题顶栏 SectionTitleBar。
- 私信（只有分享卡片，没有文字聊天）：
  - message_page.dart：消息页（顶栏右侧「面对面」玻璃圆钮，私信什么状态都在，没配中转也在），只放私信（还没有通知来源，不放空的「通知」分段，[人工决策] 在文件头）；没登录应用账号时是一张「登录应用账号后使用私信」卡（去登录经路由注入的 openAccount 推入应用账号页），私信在另一台手机上时是「在这台手机上使用」卡（takeOverSocial：先确认写明另一台停用、好友会看到、记录不过来，再原地等待接管），打开失败时是「暂时连不上」卡给重试（人工决策见 social/social_service.dart），仅本机时是「仅本机时不经服务器收发私信」卡（改为联网经 openAccount 推入应用账号页）；未开启时是开启卡片（含数据处理说明与隐私政策），开启后是添加好友与好友列表（按最近活动排序，按需建（theme 的 CampusSliverCard 与 CampusAnimatedSliverList，收到新信只重建看得见的行），下拉刷新并核对好友，增删好友时那一行原地展开、收起；时间在名字一行右端、未读角标在预览一行右端，大字号下各自长高不溢出）。
  - nearby_page.dart：面对面私信页 NearbyPage（人工决策见 social/nearby_service.dart，消息页顶栏右侧「面对面」推入）：打开即 acquire 开蓝牙、关掉 release；第一次是设昵称卡（同意并开始，附隐私政策）；上方一行原地写蓝牙状态与下一步（重试、去设置），好友行写在不在附近；登录应用账号后第一次打开问一次并进（只能二选一）；⋯里修改昵称与删除面对面数据（先确认）；从分享弹层来时（card）点在附近的好友直接发这张卡，每行原地显示发送中、已发送或失败。
  - friend_add_page.dart：添加好友（线上与面对面共用，nearby 为真时标题、加载与扫码文案按面对面，扫码用 scanNearbyInviteWithCamera；两种二维码扫错地方时说明去哪扫）：出示自己的二维码（浅色画，保证可扫）与倒计时，离开即作废；出示时本页屏幕亮度调到最高、离开恢复（screen_brightness，只改本应用窗口，[人工决策] 在 initState）；「扫一扫」扫对方的码。扫码函数可注入（InviteScanner）。
  - qr_scan_page.dart：通用扫码页 QrScanPage（给了 then 时认下的码不交回，扫码页直接换成要去的页面，只走一次转场，11-23 扫码洗浴先回首页再推时闪）：取景与相册识别都用 zxing-cpp（flutter_zxing，本机解码、不联网；换掉 ML Kit 的 [人工决策] 在文件头）。取景按 1080p 整帧找码，可两指缩放与点 1×/2×/4× 拉近（两指一落下就认作缩放，不让 iOS 右滑返回抢走），同一个码只交出一次；相册图用系统解码器缩到 2048 像素、在后台线程解。只认 QR，内容交给调用方的 accept 判断，认下就返回原文，不打开任何链接。好友二维码与课堂签到二维码共用。
  - conversation_page.dart：会话页（线上与面对面共用，经 social 的 FriendMessaging）：卡片列表最新在下，系统提示写「已成为好友」或「对方换了设备」，自己的卡片原地显示发送中、失败与重发；对方的卡片贴左、自己的贴右、最宽 82%；卡片⋯可重发或删除（仅本机）；两处 [人工决策] 都在 _item；底部只有分享课表（没登录教务时不画这一栏，界面配置卡片 11-16 删掉）；对方解除好友后改为提示。
  - share_card_view.dart：卡片渲染：课表（查看与对比，收到的可导入）、视频（打开）、已删掉的类型（界面配置，写已不再支持）、未知类型（提示更新应用）。
  - friend_schedule_page.dart：好友课表与「共同空闲」（读本机同学期课表按日期对齐）；没有同学期课表或缺开学日时如实说明；顶栏可导入到自己的课表。
  - schedule_merge_view.dart：逐项合并的列表行（MergeCheckRow、MergeChangedCourse、MergeWholeCourse），好友课表导入与教务课表合并共用。
  - schedule_import.dart：好友课表导入 importSharedSchedule：先读好本机课表再打开导入页（推入根导航器），顶部分段「逐项合并 / 整份替换」：逐项合并按 domain 的 planScheduleMerge 列出有改动的课（每处差异一行、原来的划掉，整门可半选）、TA有你没有的课、你有TA没有的课（勾上会删掉），默认只勾有同一个教学班的那几门课的改动；应用按钮原地转圈，与其余课重叠时先确认；都存成当前账号的新版本、可在历史版本恢复，开学日与作息不动，成功的提示条回到发起页显示；本机没有那个学期时说明原因、不联网（[人工决策] 在文件内）。会话卡片与好友课表页共用。
  - share_target_sheet.dart：分享弹层 showShareSheet（有面对面时最上面一行「面对面发送」推入面对面页，私信没就绪时弹层照样打开、下面写原因与去处理的按钮；私信没就绪或没有好友时按状态弹确认框，按钮经组合根套的 ShareGuide 直达应用账号页（登录、改为联网）或消息页（开启、加好友、接管、重试），去不了的只提示）：多选好友后逐个发送，每行原地显示状态，失败的可重发；课表页、百宝箱结果页共用。
  - social_dialogs.dart：错误码文案 socialErrorText、列表时间 socialShortTime、单行输入弹窗 showSocialTextInput。
- 今天：
  - today_page.dart：今天页 TodayPage（顶栏两侧玻璃圆钮、日期居中：左边拉出侧栏（有侧栏时）、右边同步，[人工决策] 在 _layout 的顶栏行）：读当前学期的课表与作息按日浏览；同步按钮走 chooseSyncSelection → CampusSync.run → showCampusSyncReport，没同步时正中给「同步课表」；课表页的「去同步」经 TodaySyncRequest 回到这里打开同步范围（组合根创建，[人工决策] 在类上）；含作息来源确认与缺开学日引导；同步中离开时结果暂存、回来再提示；切回本页、回到前台或前台的自动同步记下结果时重读本地，学期、课表版本、开学日与作息都没变时不刷新内容（不整页重排）。顶部「此刻」卡（_ClassNow）显示上课中或下一节，课上完或没课时大字写状态、下面一行预告下一节（以后没课的日子也预告，不放右侧大号时刻，免得像课程卡），没课只在这张卡里说；到点换状态平滑过渡、开课前 15 分钟强调倒计时、5 分钟内按秒倒数、倒计时换数字时滚动、上课中此刻点定时漾开、整卡可点（[人工决策] 在 _ClassNow 上方）；看别的日子时底栏上方居中显示回「今天」胶囊（[人工决策] 见 _layout，显示时也是提示条的锚点）；上课中此刻点的漾开跟云雾同一节拍（[人工决策] 在 _TimeTrack）；单击有课卡弹只读详情（_openCourse）。
  - side_drawer.dart：今天页侧栏的内容 SideDrawerPanel（[人工决策] 在类上，11-23 用户参照 Claude 应用选定）：左上角开屏那笔签名（每次启动后第一次打开写一遍，小尺寸笔画加粗）、右上角搜索钮；常用（没编辑过用组合根给的默认）与最近（已在常用里的不重复），「编辑」推入编辑页；底部一行是自己（点了去「我的」）；列表与搜索都在 theme 的 CampusFogScroll 里（滚到顶上越往上越淡、完整档另渐进模糊）；在列表顶上往下拉，搜索钮描圈、到位铺色展开成「搜索」并轻震，松手进搜索：侧栏展开成整屏，搜索钮原地变关闭钮、输入框从它左边长出来、弹键盘；空查询列最近使用与全部分组，有字时按名字与别名排、每行写分组。打开一项先记最近，被推入的页面盖住后侧栏悄悄合上。
  - quick_entry.dart：侧栏与搜索的入口 QuickEntry 与入口目录 QuickCatalog（组合根 router.dart 汇总，页面层不认识具体功能；解锁、灰度变了经 changes 重读）。
  - quick_edit_page.dart：编辑常用 QuickEditPage：上面是常用（勾着、按住把手拖动排序），下面按分组列其余的（勾上接到末尾）；点了就存，此刻看不见的原样留在末尾（同开屏画作的播放顺序页）。
  - today_day_navigation.dart：上下拖动切日的手势 TodayDayNavigation（阈值 64、上限 120）。
  - today_date_transition.dart：切日时日期与正文按同一进度纵向交接 TodayDateTransition。
  - course_cards.dart：有课卡的只读详情 showCourseDetail（今天页与课表页共用，课表页带「编辑课程」）；当日节次卡片 CourseDayCards：有课卡（课名、教室行 CoursePlace、节次与教师；时刻列开始前上课时刻大、开始后下课时刻大；内容一栏放不下六个课名字时去掉时刻列、时刻写在内容第一行，空档同理）与空档（虚线空位框 _EmptySlot，高度随时长对数加高；虚线拼成一条路径一次画完），课表页长按展开（读屏整卡一句、长按提示展开详情）；今天页单击回调 onOpen（按下变暗、读屏整卡一句），revealNow 打开时把正在上或下一节滚进可见区；今天的课按 classMoment 分三态，时长格式 classDuration。整天没课时有顶部卡片（今天页）就不在中间重复，没有才居中写「这天没课」。人工决策见 _CourseCardBody 与 revealNow。
  - live_clock.dart：全局分钟时钟 LiveClock，整分钟唤醒、后台暂停；测试要拨时间时用 LiveClock.fixed（不挂计时器，否则真实时间到整分会盖掉拨好的时间）。liveOf 说明是否真实时钟，要秒级刷新的界面只在真实时钟下自己计时。
  - date_rail.dart：日期横条 DateRail（读屏每项一句并可点选）：高与格宽按两行字（最宽的「88/88」加粗与星期）在当前字号、字体下量，日期格内外边距固定 8（heightOf、extentOf，同课表左侧栏收窄的做法，不再随字号放大留白）。
- 课表：
  - schedule_page.dart：课表页 SchedulePage：天、学期、学年三种范围，可设开学日；标题旁写第几周，学期视图打开即展开所看日期的月与周、本周写「本周」（[人工决策] 在 _drilled）；左侧月份周次栏按最宽的一项定宽（Maple 标准字号在 360dp 上放得下），窄屏、大字号下放不下时收成卡片上方的一行横条（semesterRailWidth、semesterRailFits，两条 [人工决策] 在函数上，推荐字号也按它），各周的展开收起是 _Expand（同 Flutter ExpansionTile：收起时各周照旧画着、跟着空位一起收拢，收完才拿掉），横条同左侧栏一样有过渡（切天与学期时展开收起、点月份各周横向展开、选周滑到中间，跨月时滑到点的月份或所看的那周与展开收起同帧同曲线一起走（_StripScroll 在排版时按进度校正滚动位置），点右边的月份不会被挤出屏幕；减少动画时横条与左侧栏的月份展开都直接换），顶栏放不下标题时「今天」只留图标；列表铺到屏幕底边、末尾留出底部安全区，下缘按 CampusScrollFade 淡出；单击有课卡看只读详情、长按展开；无课时段可新增课程或安排已有课程；没同步的学期给「去同步」（onSync）；顶栏只留「今天」胶囊、「管理课程」与⋯（开学日、课前提醒、导出到日历、分享给好友，后两项按注入的服务显示）。
  - text_size_range.dart：字号条的推荐范围（下限是标准 comfortableTextSizeMin，字号条本身最小 80%）：comfortableTextSize 按屏宽与当前字体，用页面自己的改排规则（schedule_page 的 semesterRailFits、course_cards 的 courseCardColumnsFit、schedule_page 的 scheduleTitleFits；今天页顶栏 11-23 起两侧都是圆钮、不再改排）找主要页面保持原排法的最大字号，学期视图左侧栏最先撑不住，所以推荐上限就是左侧栏的上限（[人工决策] 在文件头）；textSizeAdaptations 说明某个字号下哪里会改排；扫描结论记在文件头。TextSizeComfort 是组合根在 MaterialApp.builder 里量的同一个上限（垫一层主题正文样式与页面同口径，屏宽、粗体、字体变了才重量），交给 CampusTextScale 作跟随系统的上限，TextSizeComfort.of 给开发者模式的字号记录取上限与改排处。
  - calendar_export.dart：导出到日历 exportTermCalendar：当前所看学期写成 .ics 交给日历应用；缺开学日或作息时说明原因不导出，找不到的节次不猜时刻；文件只放缓存 calendar_export 文件夹（每次先清空），经原生 CalendarExporter.kt 交出（iOS 是 CalendarExporter.swift：快速查看预览这份日历，在里面「全部添加」导入，是否给出这个按钮要真机确认）。交付函数可注入（openCalendar）。
  - reminder_dialog.dart：课前提醒设置 showReminderSettings：开关、提前时间与状态栏胶囊按学期保存（系统有实时更新才给胶囊开关），状态行如实显示安排结果，需要处理的给「开启通知」「准时提醒」「开启胶囊」。
  - schedule_calendar.dart：课表页月份轨道与周次轨道的纯函数。
  - schedule_editor_page.dart：课程管理 ScheduleEditorPage：同名的教学班合成一门显示（一位老师写在课名下，几位写在各自时段后）；新增、编辑、删除（可撤销）、清空、建空课表与历史版本入口；点卡片编辑，⋯里只有删除（[人工决策] 在课程卡列表上方）。
  - course_editor_page.dart：课程编辑 CourseEditorPage：一门课（同名的几个教学班）一起编辑，课名与学分对整门生效，老师和地点写在每个时段上，保存时按老师分回教学班；时段卡点按直接改、范围在弹窗顶部选，复制与移除在⋯里（[人工决策] 在 _SlotDialog）；周次是等宽网格、快捷选周只亮正好匹配的一项（[人工决策] 在 _weekGrid）。
  - schedule_history_page.dart：课表历史版本 ScheduleHistoryPage：按日期分组的时间线，图标分教务同步、我的修改、恢复，可筛「全部 / 我的修改 / 教务同步」，按序号游标分页；点开写恢复后和现在比会加回、会删掉、会改回，恢复带乐观锁（[人工决策] 在文件内）。
  - term_start_dialog.dart：开学日设置弹窗 editTermStart（iOS 上是系统日期选择），保存成功只出提示条写第1周从哪天开始，失败才弹窗。
- 成绩：
  - grades_page.dart：成绩页 GradesPage：学年与学期汇总、有效成绩与原始成绩，可筛选、排序、搜索；本页只同步成绩；视图切换淡出淡入（旧内容淡出后才换数据）。筛选是一行「搜索框 + 筛选按钮」，类型、范围、排序在弹层里点了就生效；成绩按行列在一张分组卡里、分数在右，不及格警示色并写明（[人工决策] 在 _filterLabel 上方与 domain/grades.dart 的 gradeFailing）；教务汇总绩点大字（_summaryFigures，缺的那一项写「—」），教务明确这学期没有成绩时只画空状态卡（_emptyGrades）、不画汇总；详情按内容高（_details）；人工决策在方法上。
- 学业：
  - academic_catalog.dart：学业功能登记 academicFeatures（[人工决策] 在类上，同百宝箱的注册表）：每项是 id（就是路径 /schedule、/grades，发出后不改）、名字、图标与页面构造器，学业页的入口与路由都从它生成；页面共用的接线 AcademicHost（网关、代次核对、会话失效、回今天页同步、去登录、课前提醒与私信）由路由给。加一项教务数据的页面只在这里登记，怎么同步登记在 application/campus_sync.dart 的 campusSyncSteps。
  - academic_page.dart：学业页 AcademicPage（服务页的「学业」，取代分开的课表、成绩两项，[人工决策] 在类上）：顶部写当前学期（学期列表第一项）、第几周与最近一次同步；有自动同步留下、等你来选的教务课表时一组「待处理」（点了同打扰时机里的 showHeldScheduleSync）；各项数据的入口（来自 academicFeatures，现在是课表、成绩）；同步（同今天页的同步范围与合并页、作息来源确认 chooseBellsSource，原地显示进度（行尾利萨茹曲线；这是动作，行尾不画「›」），结果弹窗列出这一轮改了什么）、自动同步、同步记录。只读本机（前台的自动同步记下结果时重读），联网只在点了同步之后。
  - sync_records_page.dart：同步记录 SyncRecordsPage（从新到旧，每轮一张卡写自动还是手动、时刻与一句概括（没变时写查过的几类和上次一样）；系统通知「新出了几门成绩」点开也到这里）与详情 SyncRecordPage（每类变化一张卡列出哪几门课，比对过没变的几项另列一张「和上次一样」；课表的变化可撤回：先确认，恢复同步前那一版、按当前 head 乐观锁存成新版本；等你来选的给「去处理」；查看课表、查看成绩）。人工决策见 domain/sync_record.dart。
- 同步：
  - sync_selection_dialog.dart：同步范围选择 chooseSyncSelection：学年与内容都可多选，默认读本地学期列表，点刷新才联网；11-19 起没有「自动同步」入口（只在学业页一处）。
  - sync_merge_page.dart：教务课表冲突时选择性覆盖（人工决策见 domain/auto_sync.dart）：合并页 SyncMergePage 分「逐项合并 / 整份替换」，每门课写明是谁改的，默认只勾只有教务改的，没勾任何一项时按钮是保留我的课表，整份替换要确认；页面只交回选择，落库由同步或打扰时机做；落库前先校验合并结果、删课先确认，两边看不出差别时不开页面直接用教务的。resolveScheduleSync 给手动同步用（退出同保留本地，本机课表没读到时留到打扰时机再问），showHeldScheduleSync 给打扰时机用（弹之前重读暂存的那份，先弹窗问，按返回是以后再说）；页面随账号切换被销毁时也交回（同退出），同步不挂着。
  - auto_sync_dialog.dart：自动同步设置 showAutoSyncSettings：开关、间隔、学年（当前学年或指定学年）、内容（至少留一项），点了就存，最下面只读写上次的结果（上次自动同步的时刻读同步记录里最近一条自动的，同学业页；正在跑时写正在自动同步；失败、暂停写原因）；样子同课前提醒设置。
  - campus_sync_dialogs.dart：同步结果弹窗 showCampusSyncReport：结果与未处理项，这一轮改了什么（同步记录的每类变化一行、下面列几门课），可重新登录或重新同步；教务限流停下时只说明约 1 分钟后再同步，不给立即重新同步。采用别的学期作息的确认 chooseBellsSource（今天页与学业页共用）。
- 账号与设置：
  - login_page.dart：登录页 LoginPage，也用于切换账号：验证码、记住账号确认、百宝箱、游乐场、关于（进同一个关于页，未登录也能开开发者模式、检查更新，[人工决策] 在按钮处）与法务入口；同意行在登录卡片里、登录按钮正下方（[人工决策] 在同意行上，11-17），勾选框读屏读整句，点「我已阅读并同意」也能勾选，放不下一行时「用户协议 和 隐私政策」整组换行、行距按文字排（_agreement）；登录按钮常亮，没填或没勾同意时原地说明，接系统自动填充（[人工决策] 在文件内）。
  - account_dialogs.dart：旧版本数据导入确认 showLegacyImport 与登录后自动提示的 LegacyImportGate；教务验证码弹窗 LoginCaptchaDialog；开启记住账号的输密码弹窗 askRememberPassword。
  - account_page.dart：教务账号页 AccountPage（标题「教务账号」，账号卡姓名下写学号 · 班级，只在这里写；AccountTitle 我的页共用、只传姓名）：记住账号（关闭即删凭据；重新开启要输密码、后台登录核对成功才保存，不换代次）、切换账号、导入旧版本数据（本机有旧数据才显示）；退出登录单独一组放最底。11-19 起没有应用账号那一行（只在「我的」页）。
  - app_account_page.dart：应用账号页 AppAccountPage（人工决策见 domain/app_account.dart：自己的账号体系，与教务各管各的，没登录教务也能进；游乐场、私信、节日提示与「我的」页都推它）：最上面一组是「开发者的话」（有信才有，没读的带小圆点）与「我的红包」（有奖品才有，点开同原来「我的」页那一行），没登录、仅本机也在（[人工决策] 在类上 11-19 那条）；没登录时「登录 / 注册」分段，「忘记密码」凭恢复码重设，「扫码登录」让已登录的手机批准；用户名与密码先在本机查格式、不合格原地说明不联网；注册与重设成功后弹出恢复码 showRecoveryCode（四位一组、可复制（经 sensitive_clipboard.dart），点「我已保存」才关，按返回不关）。登录着：用户名、修改密码（输一次新密码）、换新的恢复码（先确认）、让新设备登录（扫码函数可注入）、我上传的诊断包（配了诊断包上传才有），退出与注销各自单独一组放最底、居中红字，都先确认。开发者的话那一组下面接着是联网偏好（组标题「联网偏好」，联网 / 仅本机，改为仅本机先确认；仅本机时登录保留但收起登录与账号管理、写暂停），最底下单独一组居中红字「删除游乐场与积分」（先确认写明删哪些，仅本机或没登录只删本机），[人工决策] 在文件头。
  - app_account_join_page.dart：扫码登录：新手机出示登录二维码的页面 AppAccountJoinPage（5 分钟有效、可刷新，显示 6 位核对码与倒计时，每 3 秒问一次批准了没有、批准了返回，亮度同添加好友页调到最高；刷新与离开时不等地作废票据）；登录着的手机扫码批准 approveAppAccountJoin（扫码函数可注入 JoinScanner，先读请求方的机型与属地，确认框写核对码、机型、属地与「不是你本人操作就不要确认」，[人工决策] 在函数上）。
  - sensitive_clipboard.dart：复制敏感内容 copySensitive（恢复码用）：经通道 superxd/sensitive_clipboard，安卓 SensitiveClipboard.kt 标成敏感内容、一分钟后清掉（只在剪贴板里还是这一串时清，在后台读不到就等拿回焦点再看），iOS 是 AppDelegate.swift 里的 SensitiveClipboard（只放本机、系统到点清掉，只有 CI 编译过、真机没验）；没有通道的平台退回普通复制。人工决策见 domain/app_account.dart 的 19:18:31 那条。
  - diagnostic_uploads_page.dart：我上传的诊断包 DiagnosticUploadsPage（人工决策见 domain/diagnostic_upload.dart）：记在当前应用账号下的诊断包从新到旧，打开时读一次（点进来才联网），每行写诊断编号、上传时间、大小与几天后删除；点一行复制编号，⋯里删除（先确认，服务器上的包与记录一起删）。
  - appearance_page.dart：界面设置 AppearancePage：字号、配色、字体、深浅色、玻璃效果与背景。字号是字号条（_textSizeSection，人工决策见 local 的 textSizeMin）：数值是实际显示大小，默认跟随系统但最多到推荐上限、松在跟随会得到的那一档上回到跟随（系统字号超过推荐上限时松在「系统」刻度上存成那个大小），下方色条标这台手机的推荐范围（text_size_range.dart）、刻度标系统字号，再下面的预览卡按拖到的大小排；拖动中每过一档轻震、越过推荐上限重震，超出时说明哪里会改排，松手才改全应用（自定义图片经系统照片选择器，选图函数可注入）；字体预览用 assets/font_previews 里预先画好的图（tool/font_previews.dart 生成），不为预览加载没在用的字体；系统字体一项直接用系统字体写（族名取主题不指定字体时平台默认的那个，不能写 fontFamily: null，会被页面默认的 Maple 填上）。衬线是下载的字体包（人工决策见 domain/font_pack.dart）：没下载时写大小，点了在这张卡里原地显示进度、可取消，下好才换上；失败写原因给重试；选着却还没下（升级上来）写暂用 Maple 并给下载；本机有文件时⋯里可删除（先确认，正在用就先换回 Maple）；这个版本下不了（没配中转）又没下过时不列出来。滑杆拖动中只预览、松手保存，系统取消与读屏增减停手 300ms 补存，离开页面时存掉没存的预览。选项点了就生效，落库在 DisplaySettings 的保存锁里排队，保存时不禁用页面上的其他选项。改字号、换字体时整页重新排版，点的那一行经 theme 的 CampusAnchoredScrollController 停在手指下（字号另有连续过渡，见 local 的 CampusTextScale）。玻璃效果有自动、完整、简化、关闭四档（关闭是实色，显示自检截到画坏时组合根自动改成关闭，见 theme 的 campus_glass_probe.dart），玻璃限档时点「完整」先解除限档。字体多一项「系统字体」（安卓与 iOS 都有，默认仍是 Maple）；iOS 上不显示玻璃效果（iOS 固定磨砂档，底栏是系统的）。
  - image_copy_pick.dart：通用取图 pickImageCopy 与多选 pickImagesCopy，返回副本路径与 discard；只删插件这次新留在缓存里的副本。壁纸、相册识别二维码共用，并经组合根注入百宝箱。
  - developer_page.dart：开发者选项 DeveloperPage（开关、日志导出与清除、上传诊断包（配了中转才有；每次先确认写明内容、去向与保留期，按钮上原地显示加密中与上传百分比，传完换成诊断编号、点了复制，记到了应用账号下时提示条写明，人工决策见 domain/diagnostic_upload.dart）、复制诊断摘要、连电脑的 adb 命令、性能浮层、节日预览（播登记的每一次节日动画与两种红包揭晓，不改日期、不抽签）、运行环境；关闭开发者模式删开发者模式日志）、日志查看 DeveloperLogPage（全部或错误、错误按种类合并写出现几次、搜索、点开看全文与复制）与悬浮开发者工具 DeveloperOverlay（开发者模式下浮在所有页面上、可拖动贴边，点开可标记当前页面与一句说明、查看日志、导出、进开发者选项；自带一层 Overlay，开关时不改页面的父级结构，性能浮层也画在这层里、不用 MaterialApp 的开关（那个会给整页加一层 Stack、换父级重建），[人工决策] 在类上）。
  - developer_notes_page.dart：开发者的话（人工决策见 domain/developer_note.dart）：列表页 DeveloperNotesPage（从新到旧、没读的标小圆点、下拉刷新、没有信时写「还没有内容」；标题均衡折行）、读信页（标题、正文原样显示可复制、落款写日期）与弹出的信 showDeveloperNoteLetter（玻璃弹窗里读全文，还有别的没读时多一个「查看全部」）；点开一封即记成读过。什么时候弹由组合根按打扰时机决定（application/app_moments.dart）。信的附件按类型取 NoteAttachmentScope 里组合根登记的渲染（app_shell.dart 登记 reward），没登记或返回空的不显示。
  - festival/reward_attachment.dart：开发者的话里附的红包 RewardAttachment（[人工决策] 在类上；组合根登记成 reward 类附件，信件页不认识红包）：先问能不能领，没资格不显示，能领给「领取红包」、点了原地转圈、领到就揭晓并变「查看红包」，领过的给「查看结果」（再问一次服务器），账号天数不够、已结束、没抽中、这一批领完了（下一批再来）写一行状态；没登录给「登录应用账号领取」，应用账号变了再问；换了活动重问。
  - festival/festival_stage.dart：节日动画的舞台 showFestivalCelebration 与场景类型 FestivalScene（这一次节日、长度、按 0–1 进度画的 builder、减少动画时的静态画面、这一次红包的主题 reward）：浮层路由（下面的页面不做转场、不登记弹窗层数），放完自己淡出，点一下或返回立即淡出；减少动画时显示静态画面或通用问候、festivalStillLength 后关。节日浮层（动画与拆红包）共用系统栏样式 festivalSystemOverlay（浅色图标、导航栏透明，不用 SystemUiOverlayStyle.light，它把导航栏涂成黑条）。人工决策见 domain/festival.dart。
  - festival/festival_catalog.dart：节日登记 festivalCatalog：每一次节日一项、一次一段单独设计的动画（场景文件放本目录），编号发出后不改；现在一项也没有，维护者点名哪个节日再加。festivalRewardTheme 按奖品的节日编号找这一次的红包主题，没登记用默认的流光卡；加一个节日主题只动两处：本目录照 reward_glow.dart 写一个 RewardTheme、场景的 reward 指向它。
  - festival/festival_reward.dart：奖品揭晓 showFestivalReward（预制，所有节日共用；卡的主题按奖品的节日找）的入口、时间线与操作：等点的那件东西浮起，点开（读屏「拆开红包」）走完开启动效的时间线，奖品卡停在正中；口令（复制并打开支付宝）或二维码（在支付宝里打开、保存二维码），「收下了」关闭；停稳的卡跟手倾斜；减少动画或从应用账号页的「我的红包」再打开时直接是卡片、不放光效与粒子、不震。画面分开启动效（reward_stardust）与奖品卡容器（reward_card）。定稿的选择（星尘、流光卡、镭射卡与春节主题没选）是 [人工决策]，在文件头。支付宝应用链接还没在真机上验过（见文件头）。
  - festival/reward_kit.dart：揭晓共用的部件：主题接口（取色用 theme 的 CampusTone） RewardTheme（配色 palette、卡面 paintCard）与配色 RewardPalette、流光卡面 RewardSurface（shaders/reward_aurora.frag：近黑玻璃卡、卡头流动的网格渐变、边上的发丝流光与外面一圈光，卡形从一团光长出来）、一帧的状态 RewardScene、开启动效接口 RewardLook、压暗程度 rewardScrim、着色器缓存 RewardShaders（没加载好时画退路）、粒子贴图与一次画完的粒子批 RewardSprites、RewardParticles（贴图在 CPU 上算好像素再上传，不经离屏渲染，揭晓开始时 load，好之前不画粒子）。
  - festival/reward_card.dart：奖品卡容器 RewardContainer（整体一块不分卡头：主题画的卡面不裁切、外面那圈光可以画到卡外，上面是内容层；口令落在半透明白框里、二维码在白底上）与内容 RewardCard（至少宽的 1.3 倍高）、按钮 RewardButton、RewardQuietButton；节日名用宋体（衬线字体包下好了才有，没下时由系统字体显示）。
  - festival/reward_glow.dart：默认主题 RewardGlowTheme：第一轮流光方向的卡（用户认可的奖品卡样子），颜色全从种子取，渐变与流光是种子色与两侧相邻的色相；相对第一轮改了什么写在文件头。
  - festival/reward_stardust.dart：开启动效「星尘」：几百颗星尘绕中间一粒光转成斜看的盘（开普勒转速、迎着转来的一侧略亮、沿旋度噪声轻轻流动），光是白芯、柔晕与淡星芒（不画环），背后稀疏的远景星；点开盘收紧加速、拖出光尾（蓄力），放开时那粒光长成卡，星尘顺着旋转流出去描出卡边、落进卡里。浮层的底 RewardDustStage。粒子一次 drawRawAtlas。
  - about_page.dart：关于页 AboutPage（连点版本号 7 次开启开发者模式，开着时多一项开发者选项）：应用图标（assets/app_icon.webp，测试期临时图，见开源许可第五节）、版本、检查更新（传入 AppUpdates 时才有）、用户协议、隐私政策、开屏画作（传入 PaintingGallery 时才有）、开源许可、源代码与反馈问题；装了新版本 14 天内、没交过反馈时多一行「新版本反馈」（传入 AppHealth 时才有，app_feedback_dialog.dart）；版本信息与打开链接可注入。
  - painting_splash.dart：开屏画作 PaintingSplash（组合根套在 runApp 外面，自带 MediaQuery 与文字方向）：画作贴底铺满屏宽、顶边按缓动曲线渐隐融进按顶边分段色铺开的天空（推近只缩小原图取样区域、不让图超出框，[人工决策] 在类上），天空里只有一笔写出的应用名（splash_signature.dart，不写画名与说明；宽约屏宽八成、最宽 360，墨色取画作顶边最冷与最暖两色压深、沿书写方向渐变，暗天空用浅色）；从第一帧真正上屏（引擎报的首帧栅格化完）起，写完再停一会儿（约 2 秒，减少动画时不写、1.2 秒）且会话恢复后再过 450ms 转场才溶解，点一下立即溶解，最多等 4 秒；开屏完全不透明时下面的应用照常构建与布局，但不画、不接手势、动画不走（Offstage 加 TickerMode 关），要溶解时先放出来画一帧、下一帧才开始溶解（溶解按 CampusFirstFrameVsync 计时，11-17 的 [人工决策] 在类上）；溶解完从树上拿掉、下面的应用不重建，并调 onGone（打扰时机等开屏走完）；减少动画时只淡入淡出。paintingSplashImage 按屏幕实际像素解码（组合根在 runApp 前就开始解码）。系统启动图的淡出在 MainActivity.kt（Android 12 起）；系统启动图不画应用图标、只有底色，在 android res 的 values-v31 与 values-night-v31 两份 styles.xml（[人工决策] 在 values-v31）。开屏的系统栏样式不写导航栏对比度，靠 values 与 values-night 的窗口主题默认关掉系统遮罩，不然底部垫一条白条（painting_ui_test.dart 守护）。人工决策在类上。
  - splash_signature.dart：开屏一笔写出的「SuperXD」（同苹果开机的 hello）：连笔草书，Super 一笔、X 两笔、D 一笔；字形是文件顶部的节点（自由点与带笔尖方向的点，同一点写两次是尖角），运行时按 Hobby 曲线（METAFONT 同法）生成、右斜 15°，自由节点处曲率连续；书写节奏按三分之二幂律（弯越急越慢）、起笔收笔与尖角处减速、笔画间提笔（停顿加空中移动），进度 0–1 换成每笔画到的长度；SplashSignaturePainter 按比例放进给定大小，单线圆头、线宽随签名缩放，墨色两色渐变。改字形只改节点。
  - paintings_page.dart：开屏画作页 PaintingsPage：按用户排的顺序列出全部画作、标出这次开屏的那幅与不在开屏播的；顶栏「播放顺序」推入 PaintingOrderPage（每幅一行：勾选开屏播不播、缩略图、按住右侧把手拖动排序，点了就存，只剩一幅在播时不让取消，人工决策见 domain/painting.dart）；「保存到相册」原地转圈、存好原地变成「已保存」；点画作从卡片里原地放大成全屏（浮层路由，同快递身份码的全屏出示，黑底渐显到不透明），可双指缩放，点一下或返回原路缩回。
  - app_update_dialog.dart：更新弹窗 showAppUpdateDialog：可选更新给更新、稍后、跳过这个版本，点更新才下载，下载、核对、等授权、安装都在弹窗里原地切换；必须更新时关不掉（人工决策见文件内）。
  - legal_page.dart：用户协议与隐私政策 LegalPage（/legal/service、/legal/privacy），顶部显示更新日期 legalUpdated；正文经 theme 的 CampusProse 按行排版。隐私政策先摘要、再按功能分节，末尾附第三方 SDK 与服务、系统权限、保存期限三份清单与 iOS 版的不同之处（[人工决策] 在文件头；iOS 上的做法变了改附录四）；改动数据处理、新增 SDK 或权限、改上限时同步改对应一节与清单并更新日期。首次打开（含没在弹窗里同意过的老用户）由组合根弹 askLegalConsent 征得同意，不同意先二次确认再退出应用（[人工决策] 在函数上）；同意过的，有实质变化时 legalRevision 加一并改写 legalChanges，打开后弹一次 showLegalUpdateNotice（只有「知道了」才算看过）。
  - app_feedback_dialog.dart：新版本反馈 showAppFeedback（人工决策见 domain/app_health.dart）：好用或不好用必选（两个选择标签 CampusGlassChip，开始时都不选）、一句话可不写（最多 200 字），提交原地转圈，成功返回给关于页出提示条，失败原地写原因。
  - licenses_page.dart：全部依赖许可 CampusLicensesPage 与应用署名 GalaxyousAttribution。
  - third_party_page.dart：开源许可页 ThirdPartyPage，读 assets/third_party_notices.txt。

# 关键规则

- 异步结果写界面前先检查 mounted，涉及账号的再检查 isAccountCurrent；遇到 SESSION_EXPIRED 交给 onSessionExpired。
- 分支页用 TickerMode 判断是否可见；今天分支重新可见时只刷新本地数据、不联网，并展示暂存的同步报告。
- 页面平时只读本地（read 系列方法），联网只由用户显式触发：同步统一经 CampusSync，成绩页只同步成绩，同步范围弹窗里的刷新学期也要用户点。例外：应用更新的自动检查由组合根发起；用户开启的自动同步由组合根与后台任务发起（默认关闭）；私信由 SocialService 的前台长轮询送达，页面不自己定时拉取，SocialService.refresh 会同步通知监听者，不能在构建期间调用。
- 好友分享的课表可查看、对比，写进自己的课表只经 schedule_import.dart（用户确认后存成新版本）；视频交给百宝箱重新解析，首次使用来源仍由本人同意。
- 今天页只读课表，编辑入口只在课表页；课表页的有课卡与空档只在长按时展开，今天页单击有课卡看详情。
- 弹窗统一走 showCampusDialog 系列：确认用 showCampusConfirm，提示用 showCampusNotice，耗时操作用 showCampusWaiting。setState 回调不得返回 Future。
- 切日、底栏拖动等手势：拖动中只预览不提交，正常松手和系统取消分别处理；方向或手势类改动先对照 today_page.dart、today_day_navigation.dart 的人工决策，以及记忆里被否决的视觉方案。
- 「甲 · 乙」式说明行一律用 theme 的 DotSeparatedText，避免窄处与大字号下折出孤字。
- 面向用户的节次、学分与时刻只用 domain 的 periodLabel、creditLabel 与 formatCampusRelative，页面不自己拼「第x–x节」或带秒的时间。
- schedule_calendar.dart 的 semesterDays、weekDates 只有测试在用，删除前先改测试。

# 测试

- 今天与课表：side_drawer_test.dart（今天页顶栏、按钮与右滑拉出、点压暗处与返回关上、常用默认与编辑、最近、下拉进搜索与搜索结果、从侧栏打开页面后合上、入口目录的显隐、常用与最近的规则与本机记录）、today_navigation_test.dart、today_date_transition_test.dart、schedule_experience_test.dart、schedule_editor_ui_test.dart、schedule_calendar_test.dart、course_clock_performance_test.dart、calendar_export_test.dart。
- 成绩与同步：grades_ui_test.dart、sync_ui_test.dart、sync_merge_test.dart（合并页、手动同步流程、打扰时机弹窗、自动同步设置）；学业页与同步记录：academic_test.dart（服务页只有学业一项、待处理、学业页的同步与结果里的变化、同步记录列表与详情、撤回、点通知进同步记录）。
- 壳层与表单：navigation_drag_test.dart、shell_layout_test.dart（含 iOS 26 系统底栏的留位、iOS 18 自绘底栏，两者都测直接切换与再点当前项；安卓与 iOS 都只竖屏）、form_spacing_test.dart（支撑 form_layout_support.dart）。
- 排版：text_layout_test.dart（登录、今天、课表三种范围与成绩在 360dp 大字号、宋体加粗体文本、411dp 标准下不裁字、不剩一行标点、不留孤字，同意行与登录按钮（同意行在按钮正下方的卡片里）、学期视图横条；11-17 起另扫学业、我的、应用账号（没登录、登录着与最底下）、开发者的话与读信、新版本反馈、挑战一栏与总览（游戏名不省略）、几个状态长的对局页；扫描在 text_fit_support.dart）。改了页面排版、文案长短或字号相关的布局都跑它。
- 设置与关于：appearance_settings_test.dart、wallpaper_test.dart、legal_page_test.dart、about_page_test.dart、app_update_ui_test.dart；应用账号一组：app_account_test.dart（「我的」页的应用账号一行与小圆点、教务账号页没有那一行、应用账号页最上面的开发者的话与我的红包、应用账号页的注册、登录、忘记密码、扫码登录（含刷新与离开时作废票据、批准前写出请求方）、恢复码走敏感剪贴板、登录着的各项与「我上传的诊断包」）；开屏与画作页：painting_ui_test.dart（含开屏不透明时下面的应用不画、动画不走与先放出来一帧再溶解，播放顺序页的勾选、拖动排序与至少留一幅）。
- 开发者的话：account_lifecycle_test.dart（「我的」页应用账号一行与应用账号页的入口、小圆点与读信、新信在什么界面条件下弹）。
- 联网偏好与删除游乐场与积分：app_account_test.dart（组标题读屏是小节标题、改为仅本机先确认、登录保留与暂停、仅本机只删本机、退出注销与删除数据各自一组居中红字）；游乐场入口一直在：account_lifecycle_test.dart；消息页的仅本机卡：social_ui_test.dart。
- 节日：festival_test.dart（舞台、红包揭晓与按钮；信里的红包：编排、中转客户端、附件的各状态与信件页按类型渲染）、reward_sprites_test.dart（粒子贴图同原来画布画的对照；单独一个文件，因为贴图的加载全局缓存）与 account_lifecycle_test.dart（节日当天播动画、抽中接着拆红包）。
- 面对面私信页面：nearby_ui_test.dart（入口、设昵称、蓝牙状态、在附近、并进、分享模式与分享弹层的面对面发送）。
- 私信页面：social_ui_test.dart（含好友课表导入的整份替换与逐项合并、没登录应用账号与私信在另一台手机上的卡片与接管确认、会话里的换设备提示）、share_card_test.dart（分享弹层没就绪时的直达在 social_ui_test.dart）；合并规则在 schedule_merge_test.dart。
- 开发者模式：developer_mode_test.dart（含上传诊断包的确认、原地状态与诊断编号，没配中转时不出现）。
- 扫码：qr_scan_test.dart（相机打不开与没给权限的说明、单次与连续模式、同一个码只交一次、iOS 两指缩放不触发右滑返回）。
- 页面测试的合成数据网关是 fixture_campus_gateway.dart（读 assets/fixtures）。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/page
- 本目录的标记集中在：切日方向与交接、回今天胶囊、底栏拖动与安全区、课程卡长按、无课时段新增、管理课程的课程卡与时段弹窗、历史版本时间线、好友课表导入、成绩同步范围与学年汇总、旧库导入确认、法务说明、我的页与账号页和关于页的归类、同步中止提示、壁纸滑杆、课表顶栏精简、学期视图窄屏收成横条、成绩页切换淡出淡入、成绩汇总缺值写法、会话卡片⋯与排法、应用更新弹窗、节日红包揭晓的定稿。
