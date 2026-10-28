# SuperXD 项目索引

本文件与各模块的 CLAUDE.md 共同组成项目索引。本文件只放每次会话都要遵守的全局结构、命令、跨模块不变量和改动流程；模块文件记文件职责、模块规则与测试，改那个目录时才加载。细节以代码注释和带 [人工决策] 标记的注释为准，索引只给地图和指针，同一事实只写一处。

- [人工决策-2026-09-29 21:40:28] 索引采用仓库内分层 CLAUDE.md（根目录加 lib 各模块），授权 AI 创建，并在每次改动时同步维护。用户全局 CLAUDE.md 仍由 AI 只提建议、由人工修改。
- [人工决策-2026-10-17 13:25:26] 索引按官方与大厂做法重整（用户四项都选推荐）：本文件控制在 200 行内，只放全局原则、命令与流程，具体超时、上限与测试清单下沉到模块文件；application 与学习通各建模块索引；守护测试按最近的 CLAUDE.md 登记；文件条目一两行，写职责、约束与人工决策位置，行为细节以代码为准。
- 模块索引共 12 个：lib 下 domain、edu、local、gateway、device、application、page、theme、toolbox、social 各一个，外加 lib/toolbox/chaoxing 与 lib/toolbox/express。lib 根目录的 main.dart、router.dart、app_session.dart、app_diagnostics.dart、app_shortcuts.dart 登记在本文件。私信中转服务端在 server 目录，说明见 server/README.md。
- test/project_structure_test.dart 兜底两条：lib 下每个 dart 文件按文件名登记在最近的 CLAUDE.md（从所在目录往上找到 lib 为止，都没有就是本文件）；索引里提到的 dart 或 kt 文件必须真实存在。
- 写法：纯文字，只用 # 标题、- 列表与 1. 编号；不写会随提交变化的数字（测试条数、提交号、库版本号），常量写名字或指到定义处。

# 定位

- 校园课表与成绩 Flutter 应用。以 Android 为主，iOS 宿主移植中（见「已知约束」），对接单所学校的 Kingo 教务系统；另有免教务登录的百宝箱（视频解析与下载、学习通签到）。
- 功能性私信：扫码互加好友后分享课表、界面配置、短视频等卡片，没有文字聊天；经自建中转（server 目录，NestJS + MySQL + Redis）端到端加密转交。学习通代签的凭据包与应用内更新的版本清单、安装包也放在这个中转。
- 公开 Alpha 测试，仓库公开、以 GPL-3.0 开源（curve_geometry.dart 例外，见 README 许可一节）。Flutter 与 Dart 版本以 CI 配置和 pubspec.yaml 为准，依赖锁定在 pubspec.lock。
- 相关文档：设计语言 UITEMP/design_language.md；用户介绍、隐私摘要与从源码构建 README.md（只放首页要的，细节链到 docs）；百宝箱说明 docs/toolbox.md、常见问题 docs/faq.md，README 截图在 docs/images（tool/readme_demo.dart 的合成数据拍）；发布、签名与贡献约定 CONTRIBUTING.md；变更记录 CHANGELOG.md。功能、数据流向或隐私政策变了，README 的亮点与隐私要点、docs 两页一起看要不要改。

# 常用命令

- 静态检查与测试：PUB_HOSTED_URL=https://pub.dev flutter analyze；PUB_HOSTED_URL=https://pub.dev flutter test test/<文件>.dart，必要时去掉文件名跑全量。本机默认镜像会改写 pubspec.lock，所以 flutter 命令一律加这个前缀，提交前确认 pubspec.lock 没变。
- 运行：flutter run 默认是 production flavor（开发包，与 Alpha 包并装、数据不共享）。私信与代签要 --dart-define=SUPERXD_RELAY=<中转地址>，地图要 --dart-define=SUPERXD_AMAP_KEY=<key>，视频解析的 BugPK 新版来源要 --dart-define=SUPERXD_SVPARSE_KEY=<key>，三者都不写进源码（发版流水线从 release 环境的机密注入）。
- 服务端：cd server，docker compose -f docker-compose.test.yml up -d --wait 起测试库后 npm test；npm run typecheck。
- 发版由流水线 .github/workflows/release.yml 全自动完成（安卓三个架构加 iOS 未签名包）：升版本 PR 合并到 main 即构建与发布，不再要网页批准；升版本 PR 只在用户明确要求发版时开；约定与本机构建见 CONTRIBUTING.md。

# 分层与依赖方向

目录即分层，依赖只许自上而下，由 test/project_structure_test.dart 守护（[人工决策] 在文件内）。出现反向依赖时先重新划分职责，不要绕过检查。

- 根目录组合根：main.dart、router.dart、app_session.dart、app_diagnostics.dart、app_shortcuts.dart，可依赖任何层。
- page 页面：可依赖 domain、application、gateway、local、social、theme 与 app_session.dart；只经 CampusGateway 与 AccountAccess 访问业务，不直接接触 SQLite、KingoClient 或 cookie（例外只有外观页读写 DisplaySettings、开发者选项页读写开发者设置与本机日志）。
- toolbox 百宝箱：设备级、免登录，可依赖 domain、theme，不依赖教务相关任何层；分享给好友、读本应用课表（学习通推断正在上的课）都经组合根注入的回调，不依赖 social 与 application。
- social 私信：设备级的身份、好友、本机库与中转客户端，只依赖 domain；页面经 SocialService 使用。
- application 应用编排：可依赖 domain、gateway。
- device 设备能力：系统通知、桌面小组件、应用更新等适配器，只实现 domain 端口、只依赖 domain，由组合根注入；页面不直接依赖。
- gateway 网关：账号生命周期与教务网关实现，可依赖 domain、edu、local。
- edu 教务协议与页面解析、local 本地存储：都只依赖 domain。
- domain 领域核心：纯 Dart 的类型、端口与规则，只依赖自身。
- theme 主题与通用视觉组件：只依赖自身，外加日志出口 domain/campus_log.dart。

# 组合根与路由门禁

- main.dart 启动顺序：
  1. 把日志出口注入为 debugPrint，接住没被处理的异步错误与框架报错（带堆栈走 campusLog）；打开本机诊断日志与开发者设置，把出口接成 logcat 加文件两份，按开发者模式切换诊断记录（app_diagnostics.dart 的 watchDeveloperMode）；再初始化时区库、图标与第三方许可。
  2. 先问这次是不是从快捷入口冷启动（是的话跳过开屏画作、这次也不轮换）；打开开屏画作库（local/painting_library.dart，按清单顺序取这次的一幅并马上开始解码）；打开 AccountStore，组装 AppSession（含 AccountGateway 与 SecureCredentialStore）、DisplaySettings、设备级 SocialService（中转未配置或格式不对时为不可用）、AppUpdates（没配中转或不是渠道构建时为空，渠道取 appFlavor）、开发者的话 DeveloperNotes（没配中转时为空）、节日 Festivals（登记来自 page/festival/festival_catalog.dart，没配中转时只播动画不抽签）与打扰时机 AppMoments。
  3. runApp 时外面套开屏画作 PaintingSplash（page/painting_splash.dart：天空里一笔写出应用名，写完、会话恢复、转场走完才溶解，点一下立即进入，[人工决策] 在文件内；溶解完置 splashGone，打扰时机等它），开屏画作库也交给关于页；runApp 之后不等待地初始化玻璃渲染、向原生要一次低电量与省电模式状态（watchNativeLowPower），私信服务等用户同意协议与政策后再初始化（已开启私信的会立即联网），再恢复会话；百宝箱的 shareVideo 接到私信分享弹层，路由把好友分享的视频交给注册表里认得这张卡片的工具（openShared）。
  4. 恢复会话后核对协议与政策（checkLegalNotice：没在首次启动弹窗里同意过的先征得同意，同意之前不联网；同意过的有实质变化时提示一次），再启动四个监听：watchLocalSchedule 对账课前提醒与小组件，watchWidgetTheme 下发小组件配色，watchAppUpdates 清旧安装包、同意后延迟 3 秒自动检查更新并在回前台时续做安装，watchMoments 启动与回到前台记今天打开过、同意后拉一次开发者的话并补抽上次没连上的签、每次回到前台重新计这一次前台并再看一眼（信间隔不到一小时不联网）；协议弹窗与新版弹窗都由 _AccountApp 在根导航器上弹，登录页也能弹，一个提示只弹一次，协议弹窗开着时更新弹窗等它关掉。节日动画（边播边抽签，抽中的接着拆红包）、没揭晓的奖品与新信等打扰时机的内容也由 _AccountApp 弹（_promptMoment：只在首页（底栏四个根页，未登录时是登录页）且上面没有推入页面、没有弹窗、协议已同意且没有待弹的提示、开屏走完时，停稳再弹）。
- 账号代次：SuperXdApp 以 session.generation 作 key 重建账号应用，切换账号时路由和页面内存状态整体丢弃（[人工决策] 在 main.dart）。
- router.dart 门禁：会话恢复完成前停在 /boot；未登录只允许 /login、/legal 下的法务页、/toolbox 与已注册工具及其快捷入口的路由（[人工决策] 在文件内）；已登录访问 /login 回到 /today；底栏壳有今天、服务、消息、我的四个分支，外包 LegacyImportGate；课表、成绩、切换账号、法务页和百宝箱推入根导航器。
- app_session.dart：把 AccountAccess 的账号变化转成路由刷新并暂存一次性提示；expire 只让发起时的那个代次失效，旧页面不能误登出新账号。
- app_diagnostics.dart：开发者模式的接线（[人工决策] 在文件头）：运行环境 appEnvironment（开发者模式第一次开着时才读）、按设置切换 campusDiagnostics 与卡顿内存统计（每 10 秒汇总、有慢帧才记）、前后台与页面切换记录（watchRoutes 只记 go_router 的路径；命令式推入的页面由 theme 的 CampusPageRoute 按页面类名记推入与返回），切到后台时把日志写盘；recordExitReasons 每次启动记系统给的上次退出原因（异常的平时也进错误记录）。悬浮开发者工具由 main.dart 的账号应用外壳套上（page/developer_page.dart 的 DeveloperOverlay）。开发者模式只多记日志、多给调试工具，不改任何业务行为。
- app_shortcuts.dart：常用功能快捷入口的接线（人工决策在 toolbox/express/express_page.dart 的 _openIdentity）：把百宝箱注册表里登记的入口（ToolboxShortcut）画成自适应图标，经 device/app_shortcuts.dart 交给系统（长按应用图标的菜单、添加到桌面）；点了入口要去的页面记在 pending，账号应用等会话恢复好、先回首页（今天或登录页）再推入，返回就回到首页。入口 id 是「工具 id.入口 id」、页面是 /toolbox/工具 id/入口 id，已发布的 id 不要改（桌面上的快捷方式按它找回页面）。测试在 app_shortcuts_test.dart（发布、后台点入口、添加到桌面、先回首页再推入）与 account_lifecycle_test.dart（冷启动直达与门禁）；原生 AppShortcuts.kt 只有设备实测。
- 页面从路由拿到 isAccountCurrent 与 onSessionExpired：异步结果回来后先确认仍属当前账号，再写界面。
- 编排（CampusSync、CampusReminders、CampusWidgets、AppUpdates）见 lib/application/CLAUDE.md。

# 跨模块不变量（改动前逐条自查）

1. 账号隔离：账号身份是教务来源 URL 加教务确认的学号；每个账号按身份哈希用独立的 SQLite 库并校验 owner；账号索引库只存账号列表、活动账号指针和旧库认领记录。切换、退出、导入都经 AccountGateway 的切换锁，旧上下文先停止接收新请求并等在途请求结束。
2. 网关不抛异常：CampusGateway 的所有方法都返回 GatewayResult，失败带一个在 domain/gateway_code.dart 登记过的错误码。页面与同步只按错误码分支，message 只用来展示；新错误码先登记再使用。
3. 会话失效：拿到 SESSION_EXPIRED 立即停止后续请求并交给 onSessionExpired。开启了记住账号时 AccountGateway 自动恢复登录一次并重放这次请求，恢复失败或重放后仍失效就不再自动恢复。
4. 同步不误覆盖：教务页面只有明确的无课、无成绩语义才当空结果，权限、维护、截断或无法识别的页面一律报错并保留本地数据；本地已有自定义课表版本时，同步前要用户确认覆盖；采用其他学期的作息须用户明确确认，普通同步不改变已有的作息绑定。
5. 课表版本：编辑、恢复和确认覆盖都带 expectedRevisionId，在同一事务里核对当前 head，不一致返回 REVISION_CONFLICT；每学期版本数有上限，当前 head 与最近一次教务基线受保护（规则见 lib/domain/CLAUDE.md）。
6. 时间：绝对时刻一律存 UTC 的 ISO 字符串；校园时区只在 domain/campus_clock.dart 的 campusTimeZone 一处定义，今天、周次、倒计时等业务日界都经 campus_clock 计算；展示时间用 formatCampusRelative（按远近写到分钟）。
7. 凭据：用户明确勾选记住账号且认证成功后才写入系统安全存储（关闭后在账号页重新开启也要先登录核对成功）；业务 SQLite、账号索引和日志一律不存密码；用户关闭记住账号或主动退出时立即删除凭据。
8. 设备级数据：百宝箱、下载任务、显示设置（配色、字体、字号、深浅色、玻璃、自定义壁纸）、私信身份与好友、学习通账号与收藏、应用更新的检查记录与下载中的安装包、协议与政策的同意与已读修订号、开发者设置与本机日志都属于设备，切换教务账号时保留。
   - 系统安全存储的每个命名空间（记住账号、私信身份、学习通、拼多多）、本机日志目录与开发者设置 developer.json 都排除出云备份与设备迁移，新增命名空间要同时加进两份备份规则，iOS 上还要给同名的 IOSOptions（仅本机级别），排除的目录同步加进 main.dart 的 excludeFromBackup，test/legal_page_test.dart 守护。
   - 桌面小组件显示的是当前账号的课，跟着账号切换，退出登录即清空；只有它的配色跟随设备设置。
   - 自定义壁纸只经系统照片选择器读用户选中的一张，复制到应用私有目录，不上传、不申请存储权限。
   - 百宝箱不读取教务凭据或 cookie；学习通密码与 cookie 只进系统安全存储，本机不存签到记录。学习通的设备信息与 OAID 只在登录、补用户信息时现取，加密后只发给学习通，不落库。
   - 私信身份私钥只在系统安全存储，私钥与 social.db 都排除出云备份与设备迁移；只有用户「关闭私信」才删除（先删服务端设备，再清本机）。
   - 百宝箱有本机数据的工具可在首页「清除数据」（工具自己删库与凭据，框架撤同意记录），已导出的文件与上游服务器上的数据不动；工具只在 toolbox_catalog.dart 一处登记。
   - 第三方解析来源逐个来源、按授权版本单独征得同意，自动模式只尝试已启用且已同意的来源。
   - 开发者的话的本机记录（最近的信、读过与弹过的编号）与节日的本机记录（参与号、近 30 天打开过的日期、播过抽过的节日、奖品）属于设备；参与号是随机数，不关联教务账号、私信身份与设备标识。
9. 对外网络：
   - 每个外部请求都有显式超时与响应上限，只发必要字段；具体数值写在所属模块（教务 edu、解析 toolbox、代签 chaoxing、私信 social、应用更新、开发者的话与节日抽签 device）。
   - 除会话自动恢复后的一次重放、时钟偏差校正后的一次重发外，不自动重试；私信收取的长轮询是持续接收通道，失败后退避继续。
   - CampusSync 每个实例内按顺序逐项请求，今天页和成绩页各持有一个实例；成绩同步与其他教务网络请求互斥（SYNC_BUSY）；教务限流时报 RATE_LIMITED，本轮立即停止。
10. 数据保留：新增只增不删的数据，必须同时给出上限或清理策略，写进所属模块 CLAUDE.md；服务端信箱与设备的保留见 server/README.md。
11. 日志：只经 domain/campus_log.dart 的 campusLog 输出，应用入口必须注入 debugPrint 才进 logcat；格式为 [模块] action=... errorType=...，错误附完整堆栈；不写原始 HTML、链接、凭据与实名信息。由 test/project_structure_test.dart 守护。
    - 同一份输出另写进本机文件（local/diagnostic_log.dart）：平时只记错误，开发者模式记全部；保存期限与掩码规则见 lib/local/CLAUDE.md，隐私政策第八节与附录三同步写明。
    - 只在开发者模式下才有意义的诊断记录（请求耗时、页面切换、卡顿内存）先看 campusDiagnostics，对外请求统一经 campusRequestLog 记，只记路径、不记域名与查询串。
    - 新模块接入开发者模式：日志照常走 campusLog、错误带 errorType= 或堆栈即自动进本机日志与错误记录；自写 HTTP 封装的发请求处必须调 campusRequestLog（test/project_structure_test.dart 守护）；新页面优先挂 go_router 路由（按路径记），命令式推入的页面经 CampusPageRoute 按页面类名记推入与返回。
12. 界面实现：确认和提示统一用 theme/campus_transitions.dart 的 showCampusConfirm 与 showCampusNotice；setState 回调不得返回 Future，给 Future 字段赋值时用块体；只有图标的 IconButton 必须带 tooltip 作读屏标签。后两条由 test/code_conventions_test.dart 守护。
13. 公开内容不出现实名：
    - [人工决策-2026-10-15 20:20:38] 仓库公开，代码、测试数据、文档、提交信息、PR 与 Issue 的正文和评论一律不写真实姓名、手机号、学号等实名信息（含真实课表里的教师名）。
    - 写设备验证记录时，账号用「账号甲」「账号乙」等代称，测试数据用合成名字。
    - [人工决策-2026-10-15 20:24:01] 发现时已在 git 历史里的（初始提交测试数据里的一个教师名）只改当前版本，不重写历史（用户选定：重写要强推 main 与标签、所有提交号变动）。

# 界面约定（来自用户反馈，细节见自动记忆）

- 耗时操作在发起位置原地显示状态：等待、进度、可暂停或取消，完成后原地切换为下一步动作（如「打开」）。
- 可点击元素一律做成带图标的按钮。状态信息只读，不用主色；主色只留给按钮和图标。整组操作和破坏性操作收进⋯菜单，并保留确认。
- 液态玻璃只用于导航层与浮层；内容区按钮与标签用色调胶囊，顶栏透明、内容滚动时自身渐隐（见 lib/theme/CLAUDE.md）。
- 会变化的列表按稳定键排序，状态变化时条目不跳动。
- 文案简洁，少放说明性文字；账号授权、旧数据归属、删除或覆盖确认以及必要的错误文案必须保留。
- 手势、方向等偏离常见习惯的要求，先提醒用户确认再实现。
- 文字最小 14px；带浮动标签的输入框，上方间距随字号缩放（campusFieldGap）。
- 节日动画、新信这类不是用户要的内容只在打扰时机出现：上下课前后的安静期、从快捷入口进来的那次前台都不出现，每次回到前台最多一件（规则见 domain/interruption.dart 与 application/app_moments.dart）。

# 改动前检查清单

1. 读本文件和涉及目录的 CLAUDE.md，确认改动落在哪一层、依赖方向是否允许。
2. 在涉及的文件及其调用方检索人工决策：grep -rn 人工决策- lib test android/app。修改带标记的代码前，先请用户确认该决策仍然有效；用户新确认的决策，在代码处加 [人工决策-北京时间] 注释（TZ=Asia/Shanghai date，精确到秒）。
3. 查自动记忆（MEMORY.md 索引）里的相关主题：授权边界、验收证据、被否决的视觉方案、设备证据、百宝箱第三方结论、版本控制与发布。
4. 对照上面的跨模块不变量逐条自查。遇到业务取舍，先向用户说明，并给出方案让用户选择。
5. 改完后验证：flutter analyze 加所涉模块 CLAUDE.md「测试」一节列的测试，必要时全量；影响界面或运行行为的改动要在模拟器上看实际效果；提交前确认 pubspec.lock 没变。
6. 同步索引与记录：新增、删除、搬迁文件，或改变职责、流程、库表、限额时，在同一提交里更新最近的 CLAUDE.md；在 CHANGELOG 的 Unreleased 下记一条。

# 测试

- 改哪个模块先跑该模块 CLAUDE.md「测试」一节；全局规范测试 project_structure_test.dart（分层、日志、请求记录、索引登记）与 code_conventions_test.dart（setState、IconButton tooltip、路由、页面滚动区渐隐、顶栏玻璃圆钮、toImageSync 只用于云雾贴图、内嵌网页拖动归网页），每次都跑。改发版工具或 CHANGELOG 版本节时跑 release_changelog_test.dart。
- 共用的测试支撑：fixture_campus_gateway.dart（合成数据教务网关，读 assets/fixtures）、toolbox_test_support.dart、form_layout_support.dart、text_fit_support.dart（扫一屏文字的裁切、孤字与单独成行的标点）、app_update_fakes.dart、fake_relay.dart、chaoxing_fake_server.dart、chaoxing_fake_hub.dart。
- tool 下的手动入口不进 CI（发版两个工具由发版流水线调用），运行方式见各文件头：
  - 访问真实服务，只在授权环境与授权账号上手动运行：verify_edu.dart、verify_grades.dart（教务）、verify_chaoxing.dart（学习通，输出脱敏）。
  - 经真实中转、只用合成数据：verify_social.dart、verify_chaoxing_pack.dart。
  - 设备与原生验证：verify_toolbox.dart（原生下载导出）、verify_chaoxing_map.dart（高德选点，要 SUPERXD_AMAP_KEY）、motion_release_test.dart（发布包的图标字体）。
  - 发版：release_changelog.dart（从 CHANGELOG 取更新说明与 Release 正文，正文模板 release_body.md）、release_manifest.dart（生成更新清单）。
  - 生成与演示：painting_colors.dart（开屏画作清单里的尺寸与天空色，加画时跑）、readme_demo.dart（README 截图）、font_previews.dart（字体预览图）、schedule_smoke.dart、glass_preview.dart、motion_preview.dart。

# 已知约束

- 平台：Android 最低 Android 11（系统 SQLite 3.28，原因与守护见 android/app/build.gradle.kts 的人工决策），验证以模拟器（API 36、API 34）为主，只在少数真机上走过部分功能。原生通道在 android/app/src 下（入口 MainActivity.kt），各自登记在使用它的模块 CLAUDE.md。
- iOS：宿主在 ios 目录（入口 ios/Runner/AppDelegate.swift；小组件与实时活动的扩展在 ios/CourseWidgets，两边共用的在 ios/Shared；最低 iOS 16 与渠道配置的人工决策在 ios/Podfile），原生代码同样登记在使用它的模块 CLAUDE.md。本机是 Linux、没有 Mac，iOS 只在 CI 的 ios-build 作业里编译，产物是未签名 ipa，测试者用全能签加自己的证书签名安装（人工决策在 ci.yml）；没有模拟器与本机调试，iOS 结论只认用户 iPhone 上的结果。系统启动图只铺默认配色的底色（LaunchBackground）；应用自己的隐私清单 ios/Runner/PrivacyInfo.xcprivacy 登记原生代码用到的需说明理由的接口（现在只有 UserDefaults），新增这类接口时同步。各项原生能力还在补，补齐前 iOS 未验收。
- 对外开放文件只经两个 FileProvider：CalendarFileProvider（缓存 calendar_export 文件夹）与 AppUpdateFileProvider（缓存 app_update 文件夹，清单声明 REQUEST_INSTALL_PACKAGES）。
- release 包开启 R8：不带混淆规则的原生 SDK（目前是高德）要在 android/app/proguard-rules.pro 写 keep 规则，jar 里的组件（如高德定位的 APSService）还要自己在清单里声明，test/legal_page_test.dart 守护规则。CI 只跑测试；release 包由发版流水线构建，正式发版前可先试跑，用试跑产物在 arm 设备或带 ARM 转译的模拟器上走一遍原生功能。
- 暂不改动的事项（只被测试使用的公开方法、性能观察项、单校写死）记在对应模块 CLAUDE.md 的关键规则里，改动前先看。
