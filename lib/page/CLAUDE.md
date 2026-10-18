# page 页面

定位：Flutter 页面与页面级组件。
- 依赖范围：domain（端口与类型）、application（同步编排、应用更新）、social（私信服务）、theme（视觉组件）和 app_session.dart。gateway 只用 account_access.dart，local 只用 display_settings.dart。
- 页面只调用 CampusGateway、AccountAccess、SocialService 和 AppUpdates，不直接读写数据库，也不直接调用教务客户端或中转服务。页面不依赖百宝箱，打开好友分享的视频经路由注入的 VideoOpener。

# 文件职责

- 壳层与导航：
  - shell_page.dart：底栏壳 ShellPage（今天、服务、消息、我的四个分支）与可拖动底栏 DragNavigationBar：悬浮在安全区之上，内容延伸到玻璃下方，底栏占位作为各页的底部安全区；拖动时的透镜是栏玻璃的兄弟层、不被栏裁剪；「消息」带私信未读角标。
  - animated_branches.dart：分支切换 AnimatedBranches，保留每个分支的 Navigator；进出两页整屏并排平移，不淡入淡出（页内玻璃在半透明图层下取不到背景）。
  - section_pages.dart：服务页（课表、成绩、百宝箱入口）、我的页（头像卡读当前会话，姓名未知时显示学号）与底栏根页的大标题顶栏 SectionTitleBar。
- 私信（只有分享卡片，没有文字聊天）：
  - message_page.dart：消息页，分段「通知 | 私信」，默认停在私信（通知尚未接入）；未开启时是开启卡片（含数据处理说明与隐私政策），开启后是添加好友与好友列表（按最近活动排序，下拉刷新并核对好友）。
  - friend_add_page.dart：添加好友：出示自己的二维码（浅色画，保证可扫）与倒计时，离开即作废；「扫一扫」扫对方的码。扫码函数可注入（InviteScanner）。
  - qr_scan_page.dart：通用扫码页 QrScanPage：相机只认 QR、识别在本机，也可从相册识别；内容交给调用方的 accept 判断，认下就返回原文，不打开任何链接。好友二维码与课堂签到二维码共用。
  - conversation_page.dart：会话页：卡片列表最新在下，自己的卡片原地显示发送中、失败与重发；卡片⋯可重发或删除（仅本机，[人工决策] 在 _item）；底部分享课表与界面；对方解除好友后改为提示。
  - share_card_view.dart：卡片渲染：课表（查看与对比）、界面配置（预览、套用）、视频（打开）、未知类型（提示更新应用）。
  - friend_schedule_page.dart：好友课表与「共同空闲」（读本机同学期课表按日期对齐）；没有同学期课表或缺开学日时如实说明。
  - share_target_sheet.dart：分享弹层 showShareSheet：多选好友后逐个发送，每行原地显示状态，失败的可重发；课表页、界面页、百宝箱结果页共用。
  - social_dialogs.dart：错误码文案 socialErrorText、列表时间 socialShortTime、单行输入弹窗 showSocialTextInput。
- 今天：
  - today_page.dart：今天页 TodayPage：读当前学期的课表与作息按日浏览；同步按钮走 chooseSyncSelection → CampusSync.run → showCampusSyncReport；含作息来源确认与缺开学日引导；同步中离开时结果暂存、回来再提示。顶部「此刻」卡（_ClassNow）显示上课中或下一节；看别的日子时底栏上方居中显示回「今天」胶囊（[人工决策] 见 _layout）；单击有课卡弹只读详情（_openCourse）。
  - today_day_navigation.dart：上下拖动切日的手势 TodayDayNavigation（阈值 64、上限 120）。
  - today_date_transition.dart：切日时日期与正文按同一进度纵向交接 TodayDateTransition。
  - course_cards.dart：当日节次卡片 CourseDayCards：有课卡（课名、教室行 CoursePlace、节次与教师；时刻列开始前上课时刻大、开始后下课时刻大）与空档（虚线空位框 _EmptySlot，高度随时长对数加高），课表页长按展开；今天页单击回调 onOpen（按下变暗、读屏整卡一句），revealNow 打开时把正在上或下一节滚进可见区；今天的课按 classMoment 分三态，时长格式 classDuration。人工决策见 _CourseCardBody 与 revealNow。
  - live_clock.dart：全局分钟时钟 LiveClock，整分钟唤醒、后台暂停；测试要拨时间时用 LiveClock.fixed（不挂计时器，否则真实时间到整分会盖掉拨好的时间）。
  - date_rail.dart：日期横条 DateRail。
- 课表：
  - schedule_page.dart：课表页 SchedulePage：天、学期、学年三种范围，可设开学日；无课时段可新增课程或安排已有课程；顶栏只留「今天」胶囊、「管理课程」与⋯（开学日、课前提醒、导出到日历、分享给好友，后两项按注入的服务显示）。
  - calendar_export.dart：导出到日历 exportTermCalendar：当前所看学期写成 .ics 交给日历应用；缺开学日或作息时说明原因不导出，找不到的节次不猜时刻；文件只放缓存 calendar_export 文件夹（每次先清空），经原生 CalendarExporter.kt 交出。交付函数可注入（openCalendar）。
  - reminder_dialog.dart：课前提醒设置 showReminderSettings：开关与提前时间按学期保存，状态行如实显示安排结果，需要处理的给「开启通知」「准时提醒」。
  - schedule_calendar.dart：课表页月份轨道与周次轨道的纯函数。
  - schedule_editor_page.dart：课程管理 ScheduleEditorPage：新增、编辑、删除（可撤销）、清空、建空课表与历史版本入口；整卡点进编辑，编辑与删除在⋯里。
  - course_editor_page.dart：单门课程编辑 CourseEditorPage。
  - schedule_history_page.dart：课表历史版本 ScheduleHistoryPage：按序号分页，可预览差异，恢复带乐观锁；恢复的影响只在恢复确认里说明。
  - term_start_dialog.dart：开学日设置弹窗 editTermStart。
- 成绩：
  - grades_page.dart：成绩页 GradesPage：学年与学期汇总、有效成绩与原始成绩，可筛选、排序、搜索；本页只同步成绩；视图切换淡出淡入（旧内容淡出后才换数据）。
- 同步：
  - sync_selection_dialog.dart：同步范围选择 chooseSyncSelection：学年与内容都可多选，默认读本地学期列表，点刷新才联网。
  - campus_sync_dialogs.dart：同步结果弹窗 showCampusSyncReport：结果与未处理项，可重新登录或重新同步；教务限流停下时只说明约 1 分钟后再同步，不给立即重新同步。
- 账号与设置：
  - login_page.dart：登录页 LoginPage，也用于切换账号：验证码、记住账号确认、百宝箱与法务入口。
  - account_dialogs.dart：旧版本数据导入确认 showLegacyImport 与登录后自动提示的 LegacyImportGate；教务验证码弹窗 LoginCaptchaDialog；开启记住账号的输密码弹窗 askRememberPassword。
  - account_page.dart：账号页 AccountPage：记住账号（关闭即删凭据；重新开启要输密码、后台登录核对成功才保存，不换代次）、切换账号、导入旧版本数据；退出登录单独一组放最底。
  - appearance_page.dart：界面设置 AppearancePage：字号、配色、字体、深浅色、玻璃效果与背景（自定义图片经系统照片选择器，选图函数可注入）；可分享给好友（不含壁纸图片）。字体预览用 assets/font_previews 里预先画好的图（tool/font_previews.dart 生成），不为预览加载没在用的字体。滑杆拖动中只预览、松手保存，系统取消与读屏增减停手 300ms 补存，离开页面时存掉没存的预览。选项点了就生效，落库在 DisplaySettings 的保存锁里排队，保存时不禁用页面上的其他选项。玻璃限档时点「完整」先解除限档。
  - image_copy_pick.dart：通用取图 pickImageCopy 与多选 pickImagesCopy，返回副本路径与 discard；只删插件这次新留在缓存里的副本。壁纸、相册识别二维码共用，并经组合根注入百宝箱。
  - about_page.dart：关于页 AboutPage：版本、检查更新（传入 AppUpdates 时才有）、用户协议、隐私政策、开源许可、源代码与反馈问题；版本信息与打开链接可注入。
  - app_update_dialog.dart：更新弹窗 showAppUpdateDialog：可选更新给更新、稍后、跳过这个版本，点更新才下载，下载、核对、等授权、安装都在弹窗里原地切换；必须更新时关不掉（人工决策见文件内）。
  - legal_page.dart：用户协议与隐私政策 LegalPage（/legal/service、/legal/privacy），顶部显示更新日期 legalUpdated；改动数据处理时同步改隐私政策并更新日期。
  - licenses_page.dart：全部依赖许可 CampusLicensesPage 与应用署名 GalaxyousAttribution。
  - third_party_page.dart：开源许可页 ThirdPartyPage，读 assets/third_party_notices.txt。

# 关键规则

- 异步结果写界面前先检查 mounted，涉及账号的再检查 isAccountCurrent；遇到 SESSION_EXPIRED 交给 onSessionExpired。
- 分支页用 TickerMode 判断是否可见；今天分支重新可见时只刷新本地数据、不联网，并展示暂存的同步报告。
- 页面平时只读本地（read 系列方法），联网只由用户显式触发：同步统一经 CampusSync，成绩页只同步成绩，同步范围弹窗里的刷新学期也要用户点。例外：应用更新的自动检查由组合根发起；私信由 SocialService 的前台长轮询送达，页面不自己定时拉取，SocialService.refresh 会同步通知监听者，不能在构建期间调用。
- 好友分享的课表只读查看，不写进自己的课表；套用界面配置后提示条可撤销；视频交给百宝箱重新解析，首次使用来源仍由本人同意。
- 今天页只读课表，编辑入口只在课表页；课表页的有课卡与空档只在长按时展开，今天页单击有课卡看详情。
- 弹窗统一走 showCampusDialog 系列：确认用 showCampusConfirm，提示用 showCampusNotice，耗时操作用 showCampusWaiting。setState 回调不得返回 Future。
- 切日、底栏拖动等手势：拖动中只预览不提交，正常松手和系统取消分别处理；方向或手势类改动先对照 today_page.dart、today_day_navigation.dart 的人工决策，以及记忆里被否决的视觉方案。
- 「甲 · 乙」式说明行一律用 theme 的 DotSeparatedText，避免窄处与大字号下折出孤字。
- schedule_calendar.dart 的 semesterDays、weekDates 只有测试在用，删除前先改测试。

# 测试

- 今天与课表：today_navigation_test.dart、today_date_transition_test.dart、schedule_experience_test.dart、schedule_editor_ui_test.dart、schedule_calendar_test.dart、course_clock_performance_test.dart、calendar_export_test.dart。
- 成绩与同步：grades_ui_test.dart、sync_ui_test.dart。
- 壳层与表单：navigation_drag_test.dart、shell_layout_test.dart、form_spacing_test.dart（支撑 form_layout_support.dart）。
- 设置与关于：appearance_settings_test.dart、wallpaper_test.dart、legal_page_test.dart、about_page_test.dart、app_update_ui_test.dart。
- 私信页面：social_ui_test.dart、share_card_test.dart。
- 页面测试的合成数据网关是 fixture_campus_gateway.dart（读 assets/fixtures）。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/page
- 本目录的标记集中在：切日方向与交接、回今天胶囊、底栏拖动与安全区、课程卡长按、无课时段新增、成绩同步范围与学年汇总、旧库导入确认、法务说明、我的页与账号页和关于页的归类、同步中止提示、壁纸滑杆、课表顶栏精简、成绩页切换淡出淡入、会话卡片⋯、应用更新弹窗。
