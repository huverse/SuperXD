# express 快递（拼多多身份码与快递查询）

定位：百宝箱里的一个工具，对接拼多多官方账号，查询驿站待取件与绑定手机号、生成取件身份码。账号是拼多多账号，与教务、学习通都无关。协议按授权账号的互操作场景用 Dart 独立重写（来自一次性移交的逆向 SDK，不原样引入），不生成也不绕过拼多多的反爬与风控字段。框架契约（注册表、服务、清除数据）见上一级 lib/toolbox/CLAUDE.md。

- [人工决策] 新增本模块与功能范围、不加截屏保护、全屏出示等，标记位于 toolbox_catalog.dart（登记处）、express_page.dart（扫码范围）、express_identity_view.dart（截屏保护、全屏出示）。

# 文件职责

- 协议与数据：
  - express_models.dart：会话 PddSession（登录态等同账号，请求头带 AccessToken 或 Cookie 二者其一）、常量与 entry_source 枚举 PddConstants、身份码 IdentityCodeResult（expireMills 是剩余有效期）、绑定手机号、驿站待取件 StationPackagesResult（非空包裹结构无真实样本，保留 raw）、失败分类 ExpressFailure。
  - express_http.dart：请求封装，显式超时管整个请求、响应上限 1MB、日志只记路径；无状态（会话靠 PddSession 请求头带）。改版时最先坏在 expressJson。
  - express_client.dart：绑定手机号、驿站待取件、生成身份码；统一抛 ExpressFailure，40001 当未登录单独成一类。
- 本机数据与服务：
  - express_vault.dart：登录会话的系统安全存储（命名空间 superxd_pdd，deleteAll 只清这个命名空间），测试用内存版。新增命名空间已加进两份备份排除规则，test/legal_page_test.dart 守护。
  - express_service.dart：服务 ExpressService（实现 ToolboxService）：只持有会话安全存储与建客户端的工厂，无业务库（身份码不落盘、快递即查即用）。清除数据删 superxd_pdd 命名空间的会话。serviceId（express）就是工具 id，也是同意记录键。
- 状态与界面：
  - express_controller.dart：页面状态，会话恢复、三项查询与身份码生成/到期刷新；一次只跑一个请求，拿到未登录就清会话回到登录态。
  - express_login_webview.dart：拼多多官方 H5 登录页 WebView，登录后经原生 CookieManager 读 HttpOnly 的 PDDAccessToken 组装会话；只许拼多多域名、拦外部 scheme。
  - express_identity_view.dart：身份码展示，Code128 条码与二维码两种样式（固定黑白供高拍仪扫），按剩余有效期倒计时、到期由控制器刷新，附「请勿分享」提示。点码牌全屏出示：码牌从卡片原地放大进整屏白底，条码转 90° 沿长边铺开、二维码只放大，期间屏幕亮度调到最高（screen_brightness，只改本应用窗口），时长与曲线同页面转场；码到期换新时全屏页跟着换（[人工决策] 在 _zoomIn）。
  - express_page.dart：首页，首次登录前取同意（拼多多是新来源）；已登录后查绑定手机号、驿站待取件（含扫驿站码进入）、生成身份码；退出登录在⋯菜单、带确认。

# 关键规则

- 凭据：拼多多登录会话（AccessToken 与账号 Cookie）等同账号登录态，只进系统安全存储（superxd_pdd），业务库与日志都不存；清除数据或退出登录立即删除。
- 身份码是取件凭证、短时有效：不落盘、不打印、界面提示勿分享；本轮不做截屏/录屏保护。
- 第三方来源：拼多多是单独一个来源，首次使用单独征得同意（expressConsentVersion），说明有实质变化就加一档；同意记录按工具 id 记，清除数据时框架撤销。
- 网络：每个请求显式超时、响应上限 1MB、只发必要字段；不自动重试。日志走 campusLog，[Express] action=... 格式，只记路径、不记凭据与查询串。
- 合规：仅用于用户本人已授权的拼多多账号的互操作；不实现验证码/风控绕过，登录在官方页面完成。接口与风控策略可能随时变化，不保证长期可用。
- 真机已见（2026-10-20 用户发来的真机截图）：WebView 登录后取到登录态、查到绑定手机号、生成并显示身份码。
- 未实测（无真实样本或未真机联调）：驿站非空包裹列表结构、驿站二维码的真实格式（station_code 原样透传）、身份码被驿站高拍仪实际扫码、全屏出示在真机上的亮度与过渡。补验按 README 与自动记忆的验收证据边界分项报告。

# 测试

- express_protocol_test.dart：会话请求头、响应解析（身份码、绑定手机号、驿站待取件空列表）、错误码到 ExpressFailure 的映射、超时与响应上限。
- express_ui_test.dart：登录态下查询、生成身份码、到期自动换新码、全屏出示（放大与缩回的中间帧、条码旋转、亮度调高与恢复、缩回落地那一帧卡片里的码牌露出）、未登录回登录态、清除数据删会话；用假 HTTP 客户端注入 ExpressService.clientFactory，不起真实 WebView。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/toolbox/express
- 标记位于：新增模块与集成取舍（toolbox_catalog.dart）、功能范围与驿站扫码（express_page.dart）、不加截屏保护与全屏出示（express_identity_view.dart）。
