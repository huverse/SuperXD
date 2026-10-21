# express 快递（拼多多身份码与快递查询）

定位：百宝箱里的一个工具，对接拼多多官方账号，查询驿站待取件、管理取件手机号（查看、绑定、解绑）、生成取件身份码。账号是拼多多账号，与教务、学习通都无关。协议按授权账号的互操作场景用 Dart 独立重写（来自一次性移交的逆向 SDK，不原样引入），不生成也不绕过拼多多的反爬与风控字段。框架契约（注册表、服务、清除数据）见上一级 lib/toolbox/CLAUDE.md。

- [人工决策] 新增本模块与功能范围、绑定手机号扩成真正的绑定、为让绑定可用用隐藏 WebView 现取 anti_content（原「不生成反爬字段」让步）、不加截屏保护、全屏出示等，标记位于 toolbox_catalog.dart（登记处）、express_models.dart（anti_content 决定与常量）、express_page.dart（扫码范围、绑定手机号管理、首页同学习通写法、先读后开、扫驿站码取站点码、只能微信取件与去微信）、express_controller.dart（首次查驿站补关联）、express_login_webview.dart（登录先校验）、express_anti_content.dart（anti_content 实现）、express_identity_view.dart（截屏保护、全屏出示）。

# 文件职责

- 协议与数据：
  - express_models.dart：会话 PddSession（登录态等同账号，请求头带 AccessToken 或 Cookie 二者其一）、常量与 entry_source 枚举 PddConstants（含绑定用 protocol_code/scene/mobile_type/entry_source）、身份码 IdentityCodeResult（expireMills 是剩余有效期）、已绑定手机号 PddBoundMobile、绑定预检查 PddBindPreCheck（canFastBind 表示有可免短信快速绑定的已有号）、驿站待取件 StationPackagesResult（字段按官方 mdkd 包裹页的渲染取：combine_list 按驿站分组成 StationPackageGroup，组内包裹先读 combine_track_list、没有再读 list（审阅移交包说 App 版是 list，两边都无真实样本），包裹 StationPackage 的取件码去掉「取件码」前缀，送货上门只记件数；无待取件时的手机尾号服务端只给前几个、largerThan2 表示还有；带驿站码查时有站名 station_name；only_wx_scan 为真表示账号只能微信扫码取件）、近一周已取出 StationOutPackage（package_out_list：取件地址、取件时间文字、快递公司与运单号，查物流参数先取 jump_url 里的）、查物流参数 ExpressTrackQuery 与物流详情 ShippingTrack（快递公司、运单号、预计送达说明、轨迹 info 与 time；不读派件员姓名电话）、扫到的驿站码 parseStationScan（链接、App 内链、JSON、裸码取 station_code，带 t 参数为动态码）与微信取件链接 weChatStationUrl、失败分类 ExpressFailure。
  - express_http.dart：请求封装，显式超时管整个请求、响应上限 1MB、日志只记路径；无状态（会话靠 PddSession 请求头带）。改版时最先坏在 expressJson。
  - express_client.dart：查手机号列表、驿站待取件、生成身份码、查实时物流（GET /api/express/shipping/track，同官方物流页、entry_source=9，只读）、关联驿站包裹（bind/mobile/station/package，空 body、带 anti-content 头），以及绑定取件手机号（预检查、快速绑定、发短信验证码、校验、完成绑定、解绑）。统一抛 ExpressFailure；无 error_code 的成功（如预检查）也算成功；失败文案认 error_msg 与 error_message（物流接口用后者）；40001 及文案点出登录失效的归未登录（说的是验证码的文案不算）；其余服务器错误记一行错误码（不记文案）。驿站查询扫码进来时带 station_code，动态码带 dynamic_qrcode=true（同官方）。绑定类接口（除只读预检查）都带 anti-content 请求头，解绑另在 body 的 anti_content 再带一份；解绑 body 字段名是 mobile（值 mobileId）加 box_popup_service/mobile_id_scene；快速绑定 entry_source="4"、新绑定 "APP"（逆向结论）。
  - express_anti_content.dart：绑定/解绑要用的 anti_content（v2）生成端口 PddAntiContent 与隐藏 WebView 实现 WebViewAntiContent：首次用到时加载官方 mdkd 页，注入官方 chunk 跑拼多多反爬 SDK 产出 anti_content，轮询取回；有时效、每次现生成不缓存。由 ExpressService 注入、页面把其 webViewController 离屏挂成 1px WebViewWidget（挂上才稳当跑指纹）；测试注入假实现、不起真实 WebView。
  - express_cookies.dart：清掉 WebView 残留拼多多 Cookie 的共用助手 clearExpressWebCookies（无平台或失败只记日志不阻断）；登录前、退出登录、清除数据都调它（见下「关键规则」）。
- 本机数据与服务：
  - express_vault.dart：登录会话的系统安全存储（命名空间 superxd_pdd，deleteAll 只清这个命名空间），另存「已绑号的驿站包裹已关联」标记（随会话一起清），测试用内存版。新增命名空间已加进两份备份排除规则，test/legal_page_test.dart 守护。
  - express_service.dart：服务 ExpressService（实现 ToolboxService）：只持有会话安全存储、建客户端的工厂与 anti_content 生成器（生产 WebViewAntiContent、测试注入假的），以及存驿站码进相册的一次性导出、临时目录与拉起微信（url_launcher），都可注入；无业务库（身份码不落盘、快递即查即用）。清除数据删 superxd_pdd 命名空间的会话，并清 WebView 残留 Cookie。serviceId（express）就是工具 id，也是同意记录键。
- 状态与界面：
  - express_controller.dart：页面状态，会话恢复、驿站查询与身份码生成/到期刷新；一次只跑一个查询（running 记是哪个操作，按钮据此原地转圈；到期刷新另记 refreshing）。打开取件手机号管理前 loadMobiles 并发读好预检查与列表（占 running，按钮原地转圈）。另有一组绑定方法（重读列表、快速绑定、发/校验短信验证码、完成绑定、解绑），不占页面 busy（弹层自管进行中），任何一个拿到未登录都清会话回登录态并通知（弹层随之关闭）；除只读的预检查/列表外，每个绑定请求前经 _anti 向 ExpressService.antiContent 现取一个 anti_content。绑定成功后紧接着关联驿站包裹（同官方）；本账号第一次查驿站时若还没关联过先补一次（[人工决策] 在 queryStationPackages）。关联失败只记日志、不打断绑定或查询，下次查询再补。扫驿站码查过后记住站点码（stationCode），身份码同官方带上它，普通「驿站快递」查询后清空；每次查驿站更新「只能微信取件」（onlyWxScan）。verifySession 给登录页用：只读预检查明确回未登录才返回 false。loadTrack 查一件包裹的物流（占 running，trackingKey 记是哪一件，只有那一行的按钮转圈）。
  - express_login_webview.dart：拼多多官方 H5 登录页 WebView，登录后经原生 CookieManager 读 HttpOnly 的 PDDAccessToken 组装会话；只许拼多多域名、拦外部 scheme。打开登录页前先 clearExpressWebCookies 清残留 Cookie 再加载，否则会被一加载就读到作废旧 Cookie、直接判「已登录」关页返回。拿到凭据先经 verify 确认会话可用才关页，被判未登录的凭据不再重复确认、等新的（[人工决策] 在 _checkSession）。
  - express_mobile_sheet.dart：取件手机号管理弹层（showExpressMobileSheet，数据由页面先读好传入，弹层里没有加载态）：列已绑号（行内⋯里解绑、带确认）、有可快速绑定的已有号时给「绑定本账号手机号」、短信验证绑定其他手机号（输号发码→输码完成，_BindMobileDialog 两步）。绑定/解绑逐步由用户点击确认，成功后保留现有列表原地换新、高度平滑过渡，失败走提示条，未登录由控制器带回登录页并关闭本弹层。
  - express_track_sheet.dart：物流详情弹层（showExpressTrackSheet，数据由页面先读好传入）：快递公司与运单号、有预计送达才写、轨迹按返回顺序列出（第一条最新且加粗、描述可选中复制）；只读，不做官方的「订阅提醒」。
  - express_identity_view.dart：身份码展示，Code128 条码与二维码两种样式（固定黑白供高拍仪扫），按剩余有效期倒计时、到期由控制器刷新，附「请勿分享」提示。点码牌全屏出示：码牌从卡片原地放大进整屏白底，条码转 90° 沿长边铺开、二维码只放大，期间屏幕亮度调到最高（screen_brightness，只改本应用窗口），时长与曲线同页面转场；码到期换新时全屏页跟着换（[人工决策] 在 _zoomIn）。到期刷新没成功时原地写「身份码已过期」并给「刷新」；卡片里的码值保持一行，放不下整体缩小。
  - express_page.dart：首页，首次登录前取同意（拼多多是新来源，同意文案含多端登录提醒与小号绑大号的引导）；登录落地页常驻一条多端登录提醒卡（只读、不用主色）。已登录后同学习通首页的写法：账号卡（人形头像、拼多多账号、⋯ 里退出登录并确认），四个操作在卡下方单独一组；四项都原地转圈，绑定手机号读好后打开管理弹层（先读后开，[人工决策] 在 _manageMobiles），驿站快递、扫驿站码与身份码成功后把结果卡滚进可视区（顺序不变、只滚最少的距离，放得下整张露出、比屏幕高就卡顶露出且至少占半屏，到期自动换码不滚；整页用 SingleChildScrollView 一次排完，按需建的 ListView 定位不到屏幕外的卡，[人工决策] 在 _reveal），结果卡标题与全应用同字号，驿站待取件按驿站列出取件码（最醒目）与快递公司、运单号，扫码查时写「当前站点」，下面列「近一周已取出」（快递公司与运单号、取件时间、地址），每件行尾「物流」先读后开物流详情（路上还没到站的件驿站接口不给，同官方看不到）；扫驿站码按 parseStationScan 取站点码、取不到在扫码页提示（[人工决策] 在 _scanStation）；只能微信取件时不写「没有待取件」，写「这个账号目前只能用微信查询待取件」并给「去微信取件」：扫过驿站码就把这个站的微信取件链接画成纯二维码存进相册、提示在微信扫一扫里从相册选它查询取件，再用 weixin:// 拉起微信，身份码照常可生成（文案与取舍的 [人工决策] 在 _toWeChat）；查询失败用提示条，登录失效回到登录页并写明原因；退出登录连 WebView Cookie 一起清（[人工决策] 在 _buildMain 与扫码范围处）。

# 关键规则

- 凭据：拼多多登录会话（AccessToken 与账号 Cookie）等同账号登录态，只进系统安全存储（superxd_pdd），业务库与日志都不存；清除数据或退出登录立即删除。WebView 的 Cookie 另存一份、也是会话凭据：登录前、退出登录、清除数据都经 clearExpressWebCookies 清掉，残留旧 Cookie 既是凭据滞留、也会让重新登录空跑。
- 多端登录：拼多多同一账号不支持多端同时在线，本模块登录会把其他设备挤下线；同意弹窗与登录落地页都提醒，并引导小号登录后绑大号手机号。
- 绑定取件手机号：绑定/解绑是账号状态变更，必须逐步由用户点击确认（输号→发码→输码→绑定；解绑先确认），不后台自动做。绑定/解绑接口（francis 短信、apoc 绑定、lobit 解绑）都经风控：缺 anti_content 会 403/参数错，故每次请求现取 anti_content 带上（见 express_anti_content.dart）。仍不做需 anti_content 的短信登录高级接口（/api/sigerus，那是登录不是绑定）。
- 关联驿站包裹：官方在绑定成功后紧接着调 bind/mobile/station/package，把这个号绑定前就到站的件关联进本账号，不调就永远查不到这些件。1.0.0-alpha.6 漏了这一步，靠「首次查驿站补一次」补救（见 express_controller.dart 的人工决策）；以后新增任何绑定入口都要接上它。
- anti_content 合规：逆向确认 anti_content 只能在 WebView 里由拼多多自己的反爬 JS 生成，纯 Dart 生成不了。[人工决策-2026-10-20 17:22:42] 用户选「原生绑定 + 隐藏 WebView 取 anti_content」：用官方 JS 产出合法 anti_content、不自行重写风控，仅用于本人已授权账号的取件手机号绑定/解绑。这是对原「不生成也不绕过反爬字段」的让步，改动要先看 express_models.dart 的标记并与用户确认。
- 只能微信取件（only_wx_scan）：拼多多的账号级实验组，官方此时整页只提示用微信扫码。不绕过（换 UA、设备、入口都无效），只做降级提示；第三方 App 让微信打开指定网页要接微信开放平台 SDK 并登记 AppID，不做，所以只拉起微信首页、驿站码靠存相册。
- 会话失效判定：HTTP 401、424 一律当未登录（真机实测被挤下线就是 424）。10-21 审阅移交包建议 424 先看 body 的 error_code，没有 body 样本、改了可能复发，不改。
- 身份码是取件凭证、短时有效：不落盘、不打印、界面提示勿分享；本轮不做截屏/录屏保护。
- 第三方来源：拼多多是单独一个来源，首次使用单独征得同意（expressConsentVersion），说明有实质变化就加一档；同意记录按工具 id 记，清除数据时框架撤销。
- 网络：每个请求显式超时、响应上限 1MB、只发必要字段；不自动重试。日志走 campusLog，[Express] action=... 格式，只记路径与服务器错误码，不记凭据、文案与查询串。
- 合规：仅用于用户本人已授权的拼多多账号的互操作；不实现验证码/风控绕过，登录在官方页面完成。接口与风控策略可能随时变化，不保证长期可用。
- 真机已验（2026-10-20，授权小号 + 用户配合，模拟器装 arm64 release）：WebView 登录取登录态、账号卡、驿站查询、身份码生成+全屏出示（亮度拉满再恢复）、绑定管理弹层列表、异地失效回登录页（真实信号 HTTP 424）、清 Cookie 后重登显示干净登录页。详见[[express-module-scope]]。
- 真机已验（2026-10-20 晚，授权小号 + 用户配合）：解绑、快速绑定、短信绑新号（发码→校验→完成）全成功，anti_content 在本 App 的隐藏 WebView 里能稳定生成；连续多次生成都快（隐藏 WebView 常驻、不重载，约 7-9 秒/次）。实现坑（重复 push chunk 不执行、WebView 被盖住重置要重载、放稳定位置只建一次）见[[express-module-scope]]与 express_anti_content.dart 注释。
- 真机已验（2026-10-21，授权账号 + 用户配合，模拟器）：关联驿站包裹接口带 anti-content 调用成功；无待取件时服务端尾号只给两个、largerThan2 为真；绑定手机号先读后开不再突闪。驿站二维码真实内容已用用户提供的实物照片解码核对（带 station_code 参数的链接），相册识别后带站点码真实查询返回站名，带站点码生成身份码照常出码。用户提供的只能微信取件账号：登录先校验（校验通过）后登录；不带站点码查询不返回 only_wx_scan，带站点码查同一驿站才返回，界面出微信取件引导、存驿站码进相册（解码一致）、没装微信时提示，身份码照常出码。
- 仍未实测：驿站非空包裹列表结构（组内是 combine_track_list 还是 list，无真实样本）、近一周已取出与物流接口的真实返回（字段按官方页面渲染取；物流页脚本 2634 块是从拼多多公开 CDN 取的，不在移交包里）、关联驿站包裹接口是否真要 anti-content、存相册的驿站码在微信里从相册识别与 weixin:// 拉起微信（要真机装微信）、登录校验判未登录不关页那一支（WebView 不能单测，只测了 verifySession）、身份码被驿站高拍仪实际扫码。补验按 README 与自动记忆的验收证据边界分项报告。

# 测试

- express_protocol_test.dart：会话请求头、响应解析（身份码、绑定手机号列表、驿站待取件空列表与「还有更多」、按 combine_list 分组的非空列表（combine_track_list 与 list 两种键）、站名与只能微信取件、近一周已取出与物流参数的来源、物流接口的请求参数与解析、驿站码各种格式的解析与微信取件链接、绑定预检查无 error_code 也算成功）、错误码到 ExpressFailure 的映射（40001 与文案判定的会话失效、非鉴权与验证码文案不误判）、动态码的 dynamic_qrcode、绑定链路与关联驿站包裹各接口的路径与参数、超时与响应上限。
- express_ui_test.dart：登录态下查询（按钮原地转圈、失败走提示条）、点了按钮的结果卡滚进可视区（驿站卡已在按钮下方不动、身份码在屏幕外滚到整张露出、到期换码不滚）、首次查驿站补关联一次且记在本机、补关联失败不挡查询、包裹按驿站列出取件码、无待取件时尾号只写前两个加「等」、扫驿站码取站点码并写当前站点且身份码带站点码（普通查询后不带）、只能微信取件（不写没有待取件，扫过码时存驿站码进相册并拉起微信，没扫过只提示，拉不起微信时说明，身份码照常生成）、登录校验 verifySession、近一周已取出列在卡片里与物流先读后开（只有那一行转圈、其余不可点、查不到用提示条）、绑定手机号先读后开（读取时按钮转圈弹层不出，弹出那一帧即最终高度）与管理弹层（列已绑号、短信绑新号且绑后紧接着关联驿站包裹、手机号格式拦截、行内⋯解绑带确认、快速绑定本账号已有号、会话失效时弹层关闭回登录页）、退出登录在账号卡⋯、登录失效回登录页写明原因（40001 与文案两路）、生成身份码、到期自动换新码与刷新失败原地给「刷新」、码值大字号保持一行、全屏出示（放大与缩回的中间帧、条码旋转、亮度调高与恢复、缩回落地那一帧卡片里的码牌露出）、未登录回登录态、清除数据删会话；用假 HTTP 客户端注入 ExpressService.clientFactory，不起真实 WebView。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/toolbox/express
- 标记位于：新增模块与集成取舍（toolbox_catalog.dart）、anti_content 让步与绑定常量（express_models.dart）、首次查驿站补关联一次（express_controller.dart）、功能范围与驿站扫码、绑定手机号扩成真正绑定、首页同学习通写法与绑定弹层入口、绑定手机号先读后开、结果卡滚进可视区、扫驿站码取站点码、只能微信取件与去微信（express_page.dart）、登录先校验再关页（express_login_webview.dart）、anti_content 隐藏 WebView（express_anti_content.dart）、不加截屏保护与全屏出示（express_identity_view.dart）。
