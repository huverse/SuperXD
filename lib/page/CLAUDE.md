# page 页面

定位：Flutter 页面与页面级组件。
- 依赖范围：domain（端口与类型）、application（同步编排）、social（私信服务）、theme（视觉组件）和 app_session.dart。gateway 只用 account_access.dart，local 只用 display_settings.dart。
- 页面只调用 CampusGateway、AccountAccess 和 SocialService，不直接读写数据库，也不直接调用教务客户端或中转服务。页面不依赖百宝箱，打开好友分享的视频经路由注入的 VideoOpener。

# 文件职责

- 壳层与导航：
  - shell_page.dart：
    - 底栏壳 ShellPage，包含今天、服务、消息、我的四个分支。
    - 可拖动底栏 DragNavigationBar，悬浮在安全区之上；内容层延伸到玻璃下方，底栏占位作为各页的底部安全区。
    - 拖动时的玻璃透镜是栏玻璃的兄弟层，不被栏裁剪，按 iOS 底栏向四周鼓出、略超出栏沿；镜下的静止胶囊随之淡出。
  - animated_branches.dart：AnimatedBranches 负责分支切换转场，保留每个分支的 Navigator；进出两页整屏并排平移，不淡入淡出（页内玻璃在半透明图层下取不到背景），曲线同页面转场（campusSpringCurve）。
  - shell_page.dart 的底栏“消息”带私信未读角标（警示红底白字，读屏读出条数）。
  - section_pages.dart：
    - 服务页：课表、成绩、百宝箱三个入口。
    - 我的页：头像卡（点按进入账号页）、界面、关于。
    - SectionTitleBar：底栏根页的大标题顶栏（服务、消息、我的共用）。
- 私信（功能性，只有分享卡片、没有文字聊天）：
  - message_page.dart：消息页 MessagePage，分段“通知 | 私信”，默认停在私信（通知尚未接入）。
    - 私信未开启时是开启卡片（昵称、数据处理说明、隐私政策链接、同意并开启）；开启后是“添加好友”（强调）、⋯（修改昵称、关闭私信）与好友列表。
    - 好友行：头像首字、名字、最后一条摘要、时间（今天只显示钟点）与未读角标；按最近活动排序。下拉刷新（应用自己的曲线指示 CampusRefreshControl，不用 Material 转圈）并核对好友列表；分支重新可见时刷新一次。
  - friend_add_page.dart：添加好友 FriendAddPage。出示自己的二维码（浅色配色画，保证可扫）与倒计时、刷新；对方一扫，问候经前台长轮询送达，原地提示“已添加”；离开即作废二维码。“扫一扫”（强调）扫对方的码，成功后返回新好友并进入会话。扫码函数可注入（InviteScanner），测试用假扫码。
  - qr_scan_page.dart：通用扫码页 QrScanPage。相机只认 QR，识别在本机完成；也可从相册识别（复用 pickWallpaperFromGallery，用完删缓存副本）；内容交给调用方给的 accept 判断（QrAccept，返回提示文案表示不认），认下就把原文返回，不打开任何链接；有闪光灯时给手电筒按钮。好友二维码（friend_add_page.dart）与课堂签到二维码（main.dart 注入给百宝箱）共用这一页。
  - conversation_page.dart：会话页 ConversationPage。卡片列表最新在下；自己的卡片下方原地显示发送中、失败原因与重新发送、或时间；长按卡片可重发或删除（仅本机）。底部实色操作栏：分享课表（多学期时先选学期，只发本机已有课表）、分享界面；对方解除好友后改为提示。⋯：修改备注、删除好友（警示确认）。
  - share_card_view.dart：卡片渲染 ShareCardView：课表（查看与对比）、界面配置（色板预览、套用）、视频（打开）、未知类型（提示更新应用）。
  - friend_schedule_page.dart：好友课表 FriendSchedulePage。周网格看 TA 的课（点课程看详情）；“共同空闲”读本机同学期课表按日期对齐，逐格标出谁有课、双方都空的着激活色，并列出本周共同空闲时段。没有同学期课表或缺开学日时如实说明。
  - share_target_sheet.dart：分享弹层 showShareSheet。多选好友后逐个发送，每行原地显示发送中、已发送或失败原因，完成后按钮变为“完成”，失败的可重发。课表页⋯、界面页顶栏、百宝箱结果页共用。
  - social_dialogs.dart：错误码文案 socialErrorText、列表时间 socialShortTime、单行输入弹窗 showSocialTextInput（昵称、备注）。
- 今天：
  - today_page.dart：今天页 TodayPage。
    - 读取当前学期的课表和作息，按日浏览。
    - 同步按钮（点按或长按）打开同步范围选择，流程为 chooseSyncSelection → CampusSync.run → showCampusSyncReport。
    - 包含作息来源确认弹窗，缺开学日时引导设置。
    - 同步中离开今天页时，结果先暂存，回来后再提示。
    - 顶部“此刻”卡（_ClassNow，同 iOS 实时活动）：上课中或下一节的课名地点，右侧剩余时长按小时分钟，下面起止时刻进度条（课间画上一节下课到下一节上课，第一节课前不画）。
    - 看别的日子时，底栏上方居中显示“今天”玻璃胶囊（箭头指向今天所在方向，贴着底栏上沿），列表底部给胶囊让位；顶栏日期下注明相对天数；人工决策见 _layout。
    - 相邻空档合成一行；今天的课上完或今天没课时，此刻卡预告下一节（_nextClass，按今天与内容版本缓存，只读本机课表）。
    - 单击有课卡弹只读详情底部弹层（_openCourse）：当天时段、地点、教师、学分与这门课的全部上课时段。
  - today_day_navigation.dart：上下拖动切日的手势 TodayDayNavigation，拖动阈值 64，上限 120。
  - today_date_transition.dart：TodayDateTransition 让切日时的日期和正文按同一进度纵向交接。
  - course_cards.dart：当日节次卡片 CourseDayCards，有课卡与空档行，长按展开（课表页）；传入 onOpen 时单击有课卡回调（今天页弹只读详情）。今天的课按此刻分三态（classMoment）：上课中竖条按已过时间填满、已下课整卡内容淡到 55%；剩余时长只在今天页“此刻”卡显示，时长格式 classDuration（小时分钟）。有课卡左列开始与结束时刻（按本页最宽时刻对齐）、中间竖条、右列节次课名地点教师，高度按同样版式测量、只在有课卡间分剩余空间；空档是虚线空位框（_EmptySlot：与卡片同宽同圆角、尺子时刻列上开始下结束、虚线竖条、标题写空闲时长、副标题节次），高度随时长对数加高（_gapHeight），展开时框内渐显成选中卡。DotSeparatedText 是“甲 · 乙 · 丙”式说明行的统一写法：按“ · ”分项换行、学期名在“学年”后切开、分隔符挂在前一项末尾，读屏读整句；课程卡地点教师、上课时段、同步结果都用它，避免窄处与大字号下折出孤字。
  - live_clock.dart：全局分钟时钟 LiveClock，在每个整分钟唤醒，应用进入后台时暂停。
  - date_rail.dart：日期横条 DateRail。
- 课表：
  - schedule_page.dart：课表页 SchedulePage。
    - 支持天、学期、学年三种范围，可设置开学日。
    - 无课时段可新增课程或安排已有课程，也可进入课程管理。
    - 顶栏只留“今天”胶囊与“管理课程”“⋯”玻璃圆按钮；⋯菜单：开学日、课前提醒（只在传入 CampusReminders 时显示）、导出到日历与分享给好友（只在传入 SocialService 时显示，分享当前所看学期的快照）。
  - calendar_export.dart：导出到日历 exportTermCalendar。
    - 把当前所看学期的全部上课时段写成 .ics 交给日历应用导入；缺开学日、缺作息或没有可导出时段时说明原因，不导出。
    - 作息里找不到的节次不猜时刻，导出前确认未导出的时段数。
    - 交付函数可注入（openCalendar），测试用假实现；默认 openCalendarFile 写入缓存 calendar_export 文件夹（每次先清空，只留最近一份），经原生通道 superxd/calendar_export 交出，见 CalendarExporter.kt。
  - reminder_dialog.dart：课前提醒设置 showReminderSettings。开关与提前时间（5/10/15/30 分钟）按学期保存；状态行如实显示已安排几次、排到哪天、缺开学日或作息、通知未开启、可能延迟，需要处理的给“开启通知”“准时提醒”按钮。
  - schedule_calendar.dart：课表页月份轨道与周次轨道的纯函数计算。
  - schedule_editor_page.dart：课程管理 ScheduleEditorPage，可新增、编辑、删除（可撤销）、清空、建立空课表，并提供历史版本入口。课程卡整卡可点进编辑（右侧箭头），编辑与删除在右上 ⋯ 菜单（删除为警示色）；上课时段按“ · ”分项换行。
  - course_editor_page.dart：单门课程编辑 CourseEditorPage，编辑名称、教师、学分和多个上课时段。
  - schedule_history_page.dart：课表历史版本 ScheduleHistoryPage。按序号分页列出版本，可预览与当前的差异，恢复时带乐观锁；恢复的影响只在恢复确认里说明，列表上方不放说明。
  - term_start_dialog.dart：开学日设置弹窗 editTermStart。
- 成绩：
  - grades_page.dart：成绩页 GradesPage。
    - 展示学年与学期汇总，以及有效成绩和原始成绩。
    - 支持筛选、排序和搜索；在这个页面只同步成绩。
    - 学期详情与学年概览、学期、学年之间切换为淡出淡入：分段控件立即滑过去，旧内容淡出后才换数据并读本地，读到（最多等 300ms）再淡入；学期一行随模式展开收起。
- 同步：
  - sync_selection_dialog.dart：同步范围选择 chooseSyncSelection。
    - 学年和同步内容都可多选。
    - 默认读取本地学期列表，用户点刷新时才联网刷新。
  - campus_sync_dialogs.dart：同步结果弹窗 showCampusSyncReport，展示结果和未处理项，可重新登录或重新同步。每项两层：状态 · 内容 · 学期（DotSeparatedText）在上，说明次要色在下。教务限流停下时只说明约 1 分钟后再同步，不提供立即重新同步。
- 账号与设置：
  - login_page.dart：登录页 LoginPage，也用于切换账号。包含验证码、记住账号确认，以及百宝箱和法务入口。
  - account_dialogs.dart：旧版本数据导入确认 showLegacyImport，以及登录后自动提示导入的 LegacyImportGate。
  - appearance_page.dart：界面设置 AppearancePage，调整字号、配色、字体、深浅色、玻璃效果和背景；传入 SocialService 时顶栏有“分享给好友”（不含壁纸图片）。
    - 背景可选自定义图片：系统照片选择器选一张，取色后交给 DisplaySettings 保存；选图插件的缓存副本用完即删。
    - 选图函数可注入（pickWallpaper），测试用假选图。
    - 字体预览是 assets/font_previews 里预先画好的图（tool/font_previews.dart 生成，按配色着色、随字号缩放），不为预览加载没在用的字体：首次排版要在主线程解析全部字重，首帧卡近半秒、转场被吃掉。改预览文字或字体后重跑生成。
    - 模糊与透明度是两条滑杆（CampusSlider），拖动中只预览，正常松手立即保存；系统取消、读屏增减没有松手回调，停手 300ms 补存；离开页面时把没存的预览存掉。
  - account_page.dart：账号页 AccountPage（同 iOS Apple ID）。记住账号（只能在这里关闭，开启要在登录时输入密码，未开启时只读显示状态）、切换账号、导入旧版本数据一组；退出登录单独一组、红字放最底。退出后账号代次变化，账号页随旧路由一起销毁。
  - about_page.dart：关于页 AboutPage。应用名与版本（package_info_plus 读安装包）、用户协议、隐私政策、开源许可、源代码与反馈问题（url_launcher 交给系统浏览器，打不开时原地提示链接），底部应用署名。版本信息与打开链接可注入，测试用假实现。
  - legal_page.dart：用户协议与隐私政策 LegalPage（路由 /legal/service、/legal/privacy），面向公开 Alpha，顶部显示更新日期 legalUpdated；改动数据处理时同步改隐私政策并更新日期。
  - licenses_page.dart：全部依赖许可列表 CampusLicensesPage 和应用署名 GalaxyousAttribution。
  - third_party_page.dart：开源许可页 ThirdPartyPage，读取 assets/third_party_notices.txt（本项目 GPL-3.0 与第三方组件），顶部进入全部依赖许可。

# 关键规则

- 异步结果写界面前先检查 mounted，涉及账号的再检查 isAccountCurrent；遇到 SESSION_EXPIRED 交给 onSessionExpired 处理。
- 分支页用 TickerMode 判断是否可见。今天分支重新可见时只刷新本地数据、不联网，并展示暂存的同步报告。
- 页面平时只读本地（read 系列方法）。联网只能由用户显式触发：
  - 同步统一经 CampusSync 编排，成绩页只同步成绩。
  - 同步范围弹窗里的刷新学期，也需要用户点击才会联网。
  - 私信例外：联系的是自建中转服务而非教务，新消息由 SocialService 的前台长轮询送达并通知，页面不自己定时拉取；进入私信时拉一次并核对好友，下拉可手动刷新。SocialService.refresh 会同步通知监听者，页面不能在构建期间调用（放到首帧之后）。
- 好友分享的课表只读查看，不写进自己的课表；界面配置套用后提示条可撤销；视频交给百宝箱重新解析，首次使用来源仍由本人同意。
- 今天页只读课表，编辑入口只在课表页。
- 课表页的有课卡和空档都只在长按时展开，单击不展开；今天页只读，单击有课卡看详情。
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
  - 回今天胶囊（取代圆形上箭头）
  - 底栏拖动与安全区
  - 课程卡长按
  - 无课时段新增
  - 成绩同步范围与学年汇总
  - 旧库导入确认
  - 法务说明（公开 Alpha 重写）
  - 我的页与账号页、关于页的归类
  - 同步中止提示
  - 壁纸模糊与透明度滑杆
  - 课表顶栏精简
  - 成绩页切换淡出淡入
