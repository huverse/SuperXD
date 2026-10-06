# social 功能性私信

定位：设备级的好友与功能性私信（只有分享卡片，没有文字聊天）。只依赖 domain；页面经 SocialService 使用，百宝箱经组合根注入的回调使用。切换教务账号保留，退出登录不清。中转服务端在仓库 server 目录（NestJS），协议与限额见 server/README.md。

# 文件职责

- social_crypto.dart：协议 v1 的客户端密码学，与服务端 relay_crypto.ts 逐字节一致，双端共用 server/test/vectors/protocol_v1.json。
  - 设备身份 SocialIdentity：Ed25519 签名密钥加 X25519 加密密钥；设备号是签名公钥 sha256 的前 16 字节（base64url）。
  - 请求签名原文 requestCanonical、邀请凭证原文 inviteProofCanonical。
  - 信封 sealEnvelope / openEnvelope：明文 gzip 后由发送方签名，再用一次性 X25519 与收件人协商，HKDF-SHA256 派生 AES-256-GCM 密钥加密，附加数据绑定收件人设备号；解压上限 1MB。验签 verifyOpened 在确认发送方后进行。
- invite_code.dart：好友二维码内容 InviteCode（SXD1F: 前缀）：邀请号、邀请私钥种子、出示方公钥与昵称、过期时刻，二进制布局转 Base45（RFC 9285），按 QR 字母数字模式编码；validNickname 昵称规则（1–20 字，无首尾空白与控制字符）。
- identity_vault.dart：身份私钥种子的存放 IdentityVault；SecureIdentityVault 用系统安全存储（命名空间 superxd_social，已排除云备份与设备迁移）；MemoryIdentityVault 供测试。
- relay_client.dart：
  - relayBaseUrl：中转地址只来自构建参数 SUPERXD_RELAY，不写进代码；未配置时私信不可用。
  - RelayCode：错误码，与服务端 relay_error.ts 一致，另有 NETWORK、TIMEOUT、BAD_RESPONSE。
  - RelayTransport 传输端口，可按请求给超时；HttpRelayTransport 默认 15 秒，长轮询为挂起时长加 10 秒。
  - HttpRelayTransport 在断网、超时、响应格式不对时记 [RelayTransport] 日志：错误码、方法与路径、异常类型与完整堆栈，不写服务器地址与查询参数；往上只抛 RelayException 错误码。
  - RelayClient：每个请求用设备私钥签名，没有会话令牌；收到 CLOCK_SKEW 按服务器时间校正并只重发这一次。
- social_store.dart：本机库 social.db（数据库目录，已排除备份）：profile、friend、message、invite 四张表，时间存 UTC ISO 字符串。
- social_service.dart：SocialService 私信编排，是页面唯一入口。
  - 状态：loading、unavailable（未配置中转）、disabled（未开启）、ready、failed。
  - enable 生成身份、注册、保存昵称；disable 先删服务端设备再清本机。
  - createInvite / redeem 扫码加好友；refresh 拉信箱、解密验签、入库后再确认删除；send / retry 发送卡片；removeFriend、setRemark、markRead、deleteMessage。
  - polling 为真时就绪后在前台持续长轮询（每次挂起 longPollWait 25 秒，有新消息立即返回），回到前台先拉一次并核对好友，进入后台不再发起；网络失败指数退避（2 秒起、上限 60 秒），空响应快于 5 秒时等满 5 秒防空转。应用里开启，测试关闭。页面不再自己定时拉取。

# 关键规则

- 扫码即成为好友（人工决策见 social_service.dart 的 redeem 与服务端 pairing.service.ts）。二维码 5 分钟有效、期内可被多人扫，新建即作废旧的，离开出示页即作废。
- 信任链：扫码方从二维码直接拿到出示方公钥；出示方收到的问候要同时满足“设备号由问候里的签名公钥推出”“问候签名有效”“凭证由本机出示过的邀请私钥签出且绑定扫码方设备号”，服务器无法伪造好友。
- 收到的任何消息都是外部输入：解密、核对消息头（发送方、收件人、消息号格式）、验签、卡片解码（decodeShareCard）任一步失败就丢弃并记日志，照样确认删除，避免反复拉取坏消息。非好友发来的卡片同样丢弃。
- 收发幂等：发送消息号即服务端去重键，重发沿用同一号；收到的消息按消息号入库，重复投递只算一次。
- 不自动重试：发送失败记错误码，由用户点重发；唯一例外是时钟偏差校正后的一次重发。收消息的长轮询是持续的接收通道，失败后退避继续，不属于重试用户操作。应用被杀时停在“发送中”的消息启动后改为失败。
- 上限：好友 500；每个好友保留最近 200 条；邀请记录保留 31 天（覆盖信箱 30 天保留期内迟到的问候）；单条密文 256KB（服务端判定）。
- 隐私：私钥只在安全存储；服务端只见设备号、好友关系、密文大小与时间；昵称、课表、界面、作品链接都在密文里。视频卡片不带媒体直链与封面。
- 身份丢失（安全存储被清）时清空本机私信库回到未开启，旧会话已无法解密。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/social server/src
- 标记位于：前台长轮询收消息、不接推送（social_service.dart 的 startPolling）、自建加密中转与地址不写死（relay_client.dart）、身份跟设备走（social_service.dart）、扫码即成为好友（social_service.dart 的 redeem 与服务端 pairing.service.ts）、课表一次性快照与首批卡片（domain/share_card.dart）。
