# toolbox/life/pangguai 胖乖生活

定位：百宝箱「生活」的第二个子模块（id life.pangguai，路由 /toolbox/life/pangguai），对接胖乖生活（com.qiekj.user 1.148.0）的校园共享设备：登录 → 扫码或按附近门店查看设备 → 打开设备 → 有档位的选档、没有的直接下一步 → 下单 → 支付宝付款 → 使用；品类是先付后用的洗衣机（含洗鞋、烘干）、吹风机，与扫 apwork.cn 码的饮水机（扣水卡）；原生的先用后付（饮水机、淋浴）以后再说。账号是胖乖账号（手机号加短信验证码），与教务、住理都无关。协议按用户 11-27 转交的另一个 AI 的移交包 v2.3（集成契约、Android Demo、实测记录，仓库外 ~/Projects/SelfProjects/API/shenghuo/pangguai）用 Dart 从头写。碰真钱，开关 toolbox.life.pangguai 默认关、先点名给开发者测（domain/feature_flags.dart）。框架契约（子模块、服务、清除数据）见上两级 lib/toolbox/CLAUDE.md；和住理共用的金额换算与支付宝端口在 lib/toolbox/life 根目录（登记在 lib/toolbox/CLAUDE.md）。

- [人工决策] 在 pangguai_service.dart 文件头（11-27 晚用户四项选择：从头写、饮水机走原生接口、人机验证接易盾原生 SDK、系统定位自己写；其余照上一轮：多账号、第一版不用券与积分、只接支付宝、开关默认关）；11-28 起随 alpha.45 分批放量，[人工决策] 在 domain/feature_flags.dart 的 pangguaiFlag 上。

# 文件职责

- pangguai_protocol.dart：请求协议（纯计算）：两个域名、报给胖乖的版本、渠道与 UA、请求头 phoneBrand 报 SuperXD、易盾业务 ID；签名 pangguaiSign 与下单的位置签名 pangguaiRiskSign（SHA-256，照官方 App；appSecret 是安装包里人人共用的客户端常量，同住理的平台密钥）。
- pangguai_http.dart：请求封装 PangguaiHttp（经共用内核 CampusHttp，模块 pangguai）：全是 POST（表单，饮水机几个是 multipart），整次 15 秒、响应上限 1MB、不跟随跳转、不自动重试；凭据放请求头 Authorization 与表单 token 两处；请求策略同住理（11-28 统一，人工决策在 ../life_http_brake.dart）：不排队、不限并发（原来排队且「结束后再等 1 秒」，诊断包 TJEHRHFR 里点下单到拉起支付宝约 10 秒），回 403、405、429 就停这个域名 15 分钟；业务码整数 0 才算成、2 是登录失效，合作方 apwork 认 success；日志只记路径与业务码。
- pangguai_models.dart：失败分类 PangguaiFailure（含不能重发的请求没等到回复的 unsure、用户关掉人机验证的 cancelled）、PangguaiException、价变了的 PangguaiPriceChanged；外部输入边界 decode*：账户、设备 PangguaiDevice（payment 分先付后用与先用后付，状态码可能是数字，不能下单的原因 unusable）、档位 PangguaiSku（洗衣机的 unit 是约几分钟、吹风机的时长档 PangguaiTier 来自 extAttr 的 perPrice、status 为假不能选）、下单的 items（pangguaiItems：洗衣一次 1、吹风写分钟数、soldType 一定带）、试算实付、下单回执、订单 PangguaiOrder（0 待付款、1 已取消（自己取消的与没付被胖乖关掉的，11-28 真机查明，原先错当待付款）、2 使用中、3 已完成，预计结束时刻只是线索）、只认支付宝 APP 支付串、附近门店、门店机型与设备（10 空闲、20 使用中）、饮水机 PangguaiWater（登录凭据与扫码给的合作方会话分开，充值标识从 redirectUrl 取）、锁机与取水状态、用水记录、水卡充值档位与跳支付宝小程序的链接 pangguaiRechargeUri；手机位置 PangguaiPosition（GCJ-02，类型放这里，客户端因此是纯 Dart、能编成命令行探针）；金额按分（lifeCents）；胖乖的时间是不带时区的北京时间（对方协议的写法，不是业务时区），pangguaiMoment 按 IANA 名 Asia/Shanghai 换成 UTC。
- pangguai_client.dart：接口 PangguaiClient：登录三步（要不要人机验证、核对易盾结果、发短信、手机号加验证码登录）、账户、扫码、设备详情、档位、试算（不用优惠）、下单（位置与签名在请求头，没等到回复报 unsure）、订单详情与列表（页从 1 起、一页 10）、支付宝渠道与预支付、取消（cancel 把单变成已取消，接着 hidden 从列表拿掉；不是待付款的胖乖回 3122）、附近门店（GCJ-02 坐标、一页 10）、门店机型、门店设备（orgId 传 0、一页 20）、饮水机扫码、锁机（不用积分，没等到回复报 unsure）、取水状态、用水记录、水卡充值档位。
- pangguai_vault.dart：账号的系统安全存储（命名空间 superxd_pangguai，已加进两份备份排除规则，iOS 钥匙串仅本机级别）：最多 pangguaiAccountLimit 个账号的手机号、登录凭据与昵称、当前账号；按外部输入读；测试用内存版。
- pangguai_devices.dart：扫到的码 pangguaiParseCode（胖乖链接的 NQT、IMEI、SN，单独的 NQT 与 32 位十六进制的饮水机码，别的不认）；本机最近使用 PangguaiDeviceStore（工具目录下的 pangguai_devices.json，按手机号分开，每个账号最多 pangguaiRecentLimit 台；外部输入，坏了当没有，写临时文件再改名；测试用内存版）。
- pangguai_location.dart：位置端口 PangguaiLocator 与通道实现（superxd/location：安卓 android/app/src/main/kotlin/com/superxd/superxd/DeviceLocation.kt 用系统 LocationManager，iOS ios/Runner/DeviceLocation.swift 用 CoreLocation，都不带谷歌闭源库）：只在找附近门店与下单时取一次，权限由 permission_handler 问（仅使用期间），5 分钟内取过的直接用，系统给的 WGS-84 经 domain/china_coordinates.dart 换成 GCJ-02；去设置时没权限到本应用设置页、定位关着到系统定位设置（通道 superxd/location_settings）。只有真机能验。
- pangguai_captcha.dart：人机验证端口 PangguaiCaptcha 与通道实现（superxd/pangguai_captcha：安卓 PangguaiCaptcha.kt 用易盾 io.github.yidun:captcha 3.7.1.1，依赖的 Glide 在 android/app/build.gradle.kts 显式升到 AndroidX 版 4.16；iOS ios/Runner/PangguaiCaptcha.swift 用 CocoaPods 的 NTESVerifyCode 3.8.6）：两边都关上报 disableReport（不装易盾的崩溃收集），通过回 validate、关掉回空。只有真机能验。
- pangguai_service.dart：服务 PangguaiService（实现 ToolboxService，serviceId life.pangguai，同意版本 consentVersion）：要人机验证时先过易盾再交给胖乖核对（发码与登录前都问）；登录成功才记凭据、切换、退出（只删本机凭据）；run 带着凭据做一次请求，凭据失效抛 notSignedIn（登录要短信，不能后台重登）；ongoing 是首页的进行中（使用中的，与 payWindow 内新建、没付的）；inspect 打开设备（详情与档位一起取，记进最近使用）；quote 试算；place 下单（先取位置，再一起重取详情与档位、之后依次试算与下单，价变了不下单，零元的不下）；prepay 付款前核对订单与金额（订单页刚读到的直接用，没给就重查）、只走支付宝渠道；cancel 只取消没付的；water 打开饮水机；unlock 锁机前重扫拿新会话、核对水种、水卡与余额门槛。没有业务库；清除数据删安全存储与最近使用。
- pangguai_login.dart：登录表单 PangguaiLoginForm（手机号、短信验证码，发码前经页面给的 consent 取同意，发码后 60 秒才能再发，接系统自动填充；给了手机号时是重新登录这个账号、号不能改）与加账号、重新登录的页面 PangguaiLoginPage。
- pangguai_page.dart：首页 PangguaiPage：没登录是登录表单；登录了是账号卡（昵称与打码手机号 pangguaiMaskedPhone，⋯ 里切换、添加与退出）、进行中的订单（使用中写预计几点结束）、用设备（扫码与附近门店一行两个等宽，最近使用默认两台、点「全部」展开）、订单入口，下拉刷新；凭据失效时原地重新登录；扫码经 runtime 的 ToolboxQrScan，胖乖码直接换成设备页、饮水机码换成饮水机页；同意说明在 _consent（写明发给谁、存什么、用到位置与易盾）。
- pangguai_shop_page.dart：附近门店 PangguaiNearbyPage（打开时取位置，没权限或定位关着原地写明并给「去设置」；门店写距离、空闲几台与地址，「加载更多」）与门店 PangguaiShopPage（机型的选择标签，设备写名字与状态，「加载更多」，点进设备页）。
- pangguai_device_page.dart：设备页 PangguaiDevicePage（给 goodsId，扫码进来的给 code）：不能下单的写原因；洗衣机选程序（约几分钟、价、说明，选中着色），吹风机、烘干机先选位置再选时长（关着的时长不列）；被占用的程序与位置照样列出、写「暂不可用」点不了（位置是虚线空心的选择标签）；只有一个能选的档位、一个时长的直接选好；选好就试算（换选项时停 quoteSettle 没再改才发，连点几下只算最后一个），按钮写服务端的实付；下单时价变了写新价请人再点，要位置时原地写明并给「去设置」，结果不确定时给「看订单」；下好单换成订单页并开始付。
- pangguai_order_page.dart：订单页 PangguaiOrderPage（付款：核对订单（打开就付时用刚读到的那份）→ 支付宝串 → 交给支付宝 → 支付宝返回、回到前台或点「我已付款」时去胖乖查，2 秒一次、最多 15 次，变成使用中或已完成才算付好、变成已取消原地写已取消；支付宝报取消或失败查一次没付就回到能再付；⋯ 里取消订单，先确认；已取消的单不给付也没有⋯；使用中写预计几点结束与还剩多久，前台时每 15 秒再查）与订单列表 PangguaiOrdersPage（一页 10、「加载更多」）。
- pangguai_water_page.dart：饮水机页 PangguaiWaterPage：选水种（每升多少钱，出不了的写「暂不可用」、虚线空心，默认常温水）、共享水卡时选哪张、余额与门槛；「开始取水」锁机后提示到机器上按闪灯的按钮出水与停止（App 没有远程停止），前台时每 4 秒查状态、最多 15 次，结束后过一会儿重读余额与用水记录，点「好了」回到能再取水；结果不确定时给「看用水记录」；「充值」点了才读档位，跳支付宝小程序，回来重读余额。

# 关键规则

- 下单：详情与档位（一起取）→ 试算 → 下单用同一个凭据连着发，点「下单」时整串重发，不沿用打开页面时取的；items 与上一次试算一字不差；位置取不到不下单（胖乖按位置核对，下单请求头带经纬度与位置签名）；结果不确定（没等到回复）不重发，请人先看订单。
- 金额：只显示胖乖给的数，下单前以试算的实付为准，付款前再核对订单金额，变了先停下请人确认；第一版不用券与积分（试算不带优惠、饮水不用积分抵扣），手里有券的人会比官方 App 付得多。付款只接支付宝 APP 支付串（收款方是胖乖），到账只认胖乖的订单状态，支付串不进日志。
- 开机：先付后用的设备由胖乖服务器在付款成功后下发开机，客户端没有启动设备的接口；预计结束时刻会变、到点不等于完成，以订单状态为准。没付的单胖乖不给关单时刻，首页只提 10 分钟内的。
- 提示条：三页的付款区、下单区与选择卡跟着内容滚动，不包 CampusToastAnchor（包了提示条会停到页面中间压住上面的卡片，11-28 真机截图）。
- 饮水机：锁机后人在机器上按键出水与停止；结束状态不等于扣了费，订单与余额晚一点才出来，一次查不到别急着再锁；余额涨了也不当成某一笔充值到账的凭据。
- 限流：请求策略同住理（不限并发），403、405、429 就停 15 分钟；新增轮询或批量请求前先想会不会撞防火墙（校园网出口共用 IP）。付款那几步之间别插没用的请求（首页刷新等关页面时再做）。
- 凭据：登录凭据等同登录态，只进系统安全存储，退出账号或清除数据即删；胖乖不给过期时间，失效（业务码 2）时请用户重新收短信登录。
- 第三方：首次发验证码前单独征得同意（consentVersion），说明有实质变化就加一档；同意记录按 life.pangguai 记，清除数据时框架撤销。隐私政策与用户协议里写胖乖、易盾 SDK、apwork 与位置，改采集或去向要同步。
- 保留：账号最多 10 个；本机只存最近使用（每个账号 6 台），不存订单、余额与用水记录。
- 没做（第一版）：优惠券与积分、胖乖余额与其他付款方式、加购、预约、原生的先用后付（饮水机、淋浴）、蓝牙、退款、绑卡与停卡、水卡充值记录。

# 测试

- pangguai_test.dart：协议与数据（签名向量用 Python 独立算、认码、档位与时长档和 items、设备不能下单的原因、订单状态与北京时间换算、只认支付宝串、饮水机两套凭据与充值标识、充值链接的两次编码）、请求（凭据两处都带与签名头、下单的位置头、业务码 2、405 停住不再发、不排队（一起发的同时在路上）、合作方的 success 与 token）、服务（人机验证先过易盾再核对、关掉不发码、登录才记凭据与多账号、下单四步的顺序与价变了不下单与取不到位置不发请求与结果不确定、付款前核对与只走支付宝、首页进行中的筛选、取消、已取消的单不进首页不给付不再取消、锁机前核对与参数与结果不确定、安全存储按外部输入读与清除数据）、页面（登录先同意再验证再发码与倒数、洗衣机选程序到下单付款到使用中、支付宝里取消与取消订单、付款时单被关掉写已取消、被占用的位置与程序写暂不可用点不了而能选的只剩一个时直接选上、吹风机选位置与时长、不能用的设备与要位置的去设置、饮水机取水全程与余额不够与充值档位、凭据失效原地重新登录与扫码直接换页、附近门店到门店到设备页）、注册表与开关；假胖乖、假支付宝、假定位与假人机验证都在文件里，数据全是合成的。
- 真实后端与真机只在授权账号上手动验（要用户给胖乖测试账号并转告短信验证码；真实下单付款要用户点头），探针放 build/superxd_verify，不进仓库；易盾、系统定位与支付宝只有真机能验。
