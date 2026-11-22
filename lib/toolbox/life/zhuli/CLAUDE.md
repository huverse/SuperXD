# toolbox/life/zhuli 住理生活

定位：百宝箱「生活」的第一个子模块（id life.zhuli，路由 /toolbox/life/zhuli，灰度开关 toolbox.life.zhuli 默认关），对接住理生活（com.whxinna.userplatform 3.12.8）的校园水控：洗浴开关、充值与买券、余额与优惠券、订单。账号是住理生活账号，与教务、学习通都无关；协议按资料 ~/Projects/SelfProjects/API/shenghuo/zhuli（集成文档、逆向报告、样本，仓库外）用 Dart 重写，11-22 用两个授权测试账号实测过。分轮做：第一轮（现在）是登录、余额与券、订单只读；之后是洗浴四个入口与开关、充值与买券（支付宝 SDK）、进行中通知、蓝牙开阀与报修。框架契约（子模块、服务、清除数据）见上两级 lib/toolbox/CLAUDE.md。

- [人工决策] 在 zhuli_service.dart 文件头（11-22 用户两轮选项：灰度、风险立场与不碰的后门和越权点、支付、设备列表、充值金额、余额与券的显示、增项、不做强制结束与消费投诉；登录方式与改选短信找回密码）。

# 文件职责

- zhuli_protocol.dart：请求协议（纯计算）：平台端地址与写死的签名密钥、上报的 App 版本；签名 zhuliSign（去空值、按键排序、值按 JS 的 JSON.stringify、去引号与空格、MD5 转大写，向量来自被真实服务端接受的实现）、对象参数换成 base64_<名>（zhuliBase64，同原 App 的 base64 再换 - 与 _）、带时刻与 32 位随机串的查询参数 zhuliQuery、回复 data 的 base64 解码 zhuliDecodeData。
- zhuli_http.dart：请求封装 ZhuliHttp（经共用内核 CampusHttp，模块 zhuli）：只发 GET，整次 15 秒、响应上限 1MB，不自动重试；result 为假时 zhuliRejection 按 err_msg 与 msg 归类（login_timeout 是会话过期，三种图形验证码文案要验证码，中文文案原样给人看）；日志只记路径与英文错误码，不记查询串（有手机号、密码、签名）与回复。
- zhuli_models.dart：失败分类 ZhuliFailure 与 ZhuliException；外部输入边界 decode*（逐项核对类型）：登录会话 ZhuliSession（业务地址只认 https 的 whxinna.com 主机、session_secret 盖过 appsecret，只在内存）、账户 ZhuliProfile（余额以用户详情为准，登录回复里的不可信）、配置 ZhuliConfig（消费订单可查天数）、券 ZhuliCoupon 与三栏 ZhuliCouponTab（回复里的 status、is_blance 恒为空，只能靠入参过滤）、券的抵扣记录、充值订单、消费订单与详情 ZhuliBill；金额一律按分的整数（zhuliCents 按十进制文本四舍五入到分，不经浮点运算，zhuliYuan 写回元）；状态、消费类型、支付方式的中文。
- zhuli_client.dart：接口 ZhuliClient：登录（手机号加 6 位数字密码，只报系统类型与本工具的随机设备串、机型报 SuperXD）、图形验证码（SVG）、找回密码（短信验证码与重设）、用户详情、配置、我的券（页从 0 起）、券的月度抵扣记录（page_index 0 是整月）、充值订单（页从 1 起、不满 20 条到底）与详情、消费订单（起止必填、一次最多 20 条，用上一页最后一条的时刻翻页）与详情。住理的时间是不带时区的北京时间（对方协议的写法，不是业务时区）：zhuliMoment 换成 UTC 交给界面、zhuliClock 把时刻写回去，只在这里换算。
- zhuli_vault.dart：账号的系统安全存储（命名空间 superxd_zhuli，已加进两份备份排除规则，iOS 钥匙串仅本机级别）：最多 zhuliAccountLimit 个账号的手机号与密码、当前账号与本工具的随机设备串；按外部输入读（坏了整份当没有）；测试用内存版。
- zhuli_service.dart：服务 ZhuliService（实现 ToolboxService，serviceId life.zhuli，同意版本 consentVersion）：登录成功才记密码并设为当前账号，切换、退出（只删本机密码）；run 带着账号的会话做一次请求，没有会话先用记着的密码登录，login_timeout 自动重登一次再重放（同一账号同时只重登一次），重登被拒归 notSignedIn、要验证码原样抛给页面；couponBalance 把未使用的券加起来（最多 5 页）；没有业务库，清除数据删安全存储与内存里的会话。
- zhuli_login.dart：登录表单 ZhuliLoginForm（手机号、6 位数字密码、住理要时原地出 SVG 图形验证码可换一张，接系统自动填充；第一次登录前经页面给的 consent 取同意；给了手机号时是重新登录这个账号、号不能改）、加账号与重新登录的页面 ZhuliLoginPage、短信找回密码 ZhuliResetPage（发码后 60 秒倒数，两次新密码一致且是 6 位数字才提交）。
- zhuli_page.dart：首页 ZhuliPage：没登录是登录表单；登录了是账号卡（学校名与打码手机号 zhuliMaskedPhone，⋯ 里切换、添加与退出账号）、余额与券余额（只读、不用主色，服务端给的数）、优惠券与订单两个入口，下拉刷新；会话恢复不了时在账号卡下原地重新登录；切换账号后旧账号晚回来的结果不写界面。同意说明在 _consent（写明发给谁、存什么）。
- zhuli_coupons_page.dart：我的优惠券 ZhuliCouponsPage（未使用、已用完、已失效三栏，一页 20 张、点「加载更多」接着读，券上写余额、面额、适用范围、先用券还是先用余额与到期）与券的抵扣记录弹层（按月翻，最早到券生效那个月）；zhuliShownTime 把住理时间按校园时区的远近写法显示。
- zhuli_orders_page.dart：订单 ZhuliOrdersPage（消费与充值两栏，「加载更多」往回翻；消费单按项目配置的可查天数、没配时 zhuliConsumeDays）与详情弹层（消费：设备、位置、用水升数与秒数、预扣、实扣、退回、券与余额各扣多少；充值：金额、状态、支付方式、到账时刻与到账后余额）。

# 关键规则

- 不用资料里靠测试手机号触发的 mp.whxinna.com 调试转发；staff_id 一律空（只查自己的）；资料第 14 节列的越权点（URL 透传的 staff_id、伪造结果页这类）一个都不碰。
- 网络：住理的两个域名在阿里云高防后面，国内网络直连通、境外出口超时（11-22 实测）；开发机上的探针要绕开代理软件走国内出口。
- 凭据：密码登录成功后才进系统安全存储，退出账号或清除数据即删；会话（签名密钥与身份码）只在内存，约 20–40 分钟过期，过期按记着的密码重登。余额、券与订单即查即用、不落盘。
- 金额：只显示服务端给的数，客户端不推算抵扣（住理按券的 use_order 自己扣，客户端没法选券）；金额按分的整数处理。
- 第三方来源：首次登录前单独征得同意（consentVersion），说明有实质变化就加一档；同意记录按 life.zhuli 记，清除数据时框架撤销。隐私政策第七节、用户协议第八节、附录一第 9 项与附录三本机第 17 项写明，改采集或去向要同步。
- 保留：账号最多 10 个；本机不存任何业务数据。

# 测试

- zhuli_test.dart：协议（签名向量、查询参数、base64、金额与时间换算、登录回复的地址校验、错误归类）、会话（登录才记密码、过期自动重登并重放且几处一起等同一次、重登被拒与要验证码、切换与退出、最多 10 个、清除、安全存储内容按外部输入读、券余额）、页面（没登录先同意再登录、图形验证码、密码改过后原地重新登录、账号菜单切换与退出、优惠券三栏与抵扣记录、订单的天数与翻页和详情、找回密码）、注册表（两层开关与路由）；假住理在文件里（MockClient，回复照真实服务端写成 base64，数据全是合成的）。
- 真实后端只在本机手动验（探针放 build/superxd_verify，不进仓库；凭据只在会话临时目录）。
