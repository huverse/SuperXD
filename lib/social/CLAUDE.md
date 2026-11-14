# social 功能性私信

定位：好友与功能性私信（只有分享卡片，没有文字聊天），11-14 起跟着当前应用账号（人工决策见 social_service.dart 文件头）：每个应用账号在这台手机上一份，没登录应用账号时停用。只依赖 domain；页面经 SocialService 使用，百宝箱经组合根注入的回调使用。退出应用账号、切换或退出教务都不清本机。中转服务端在仓库 server 目录（NestJS），协议与限额见 server/README.md。

# 文件职责

- social_crypto.dart：协议 v1 的客户端密码学，与服务端 relay_crypto.ts 逐字节一致，双端共用 server/test/vectors/protocol_v1.json。
  - 设备身份 SocialIdentity：Ed25519 签名密钥加 X25519 加密密钥；设备号是签名公钥 sha256 的前 16 字节（base64url）。
  - 请求签名原文 requestCanonical、邀请凭证原文 inviteProofCanonical、私信设备挂到应用账号的凭证原文 socialBindCanonical（共用向量 socialBind）。
  - 信封 sealEnvelope / openEnvelope：明文 gzip 后由发送方签名，再用一次性 X25519 与收件人协商，HKDF-SHA256 派生 AES-256-GCM 密钥加密，附加数据绑定收件人设备号；解压上限 1MB。验签 verifyOpened 在确认发送方后进行。
- invite_code.dart：好友二维码内容 InviteCode（SXD1F: 前缀）：邀请号、邀请私钥种子、出示方公钥与昵称、过期时刻，二进制布局转 Base45（RFC 9285），按 QR 字母数字模式编码；validNickname 昵称规则（1–20 字，无首尾空白与控制字符）。
- identity_vault.dart：私信身份私钥种子的存放 IdentityVault（每个应用账号一项，键由 social_spaces.dart 定；另记旧版私信归哪个账号 legacyOwner）；SecureIdentityVault 用系统安全存储（命名空间 superxd_social，已排除云备份与设备迁移）；MemoryIdentityVault 供测试。
- social_spaces.dart：每个应用账号一份私信 SocialSpaces：本机库与身份的键。旧版留下的设备级私信（库 social.db、身份 identity）归这台手机上第一个用私信的应用账号（legacyOwner），其余账号库在数据库目录的 social/<账号号>.db、身份 identity.<账号号>（social 文件夹整个排除备份，两份备份规则与 iOS 的 excludeFromBackup 都有，test/legal_page_test.dart 守护）；库只开一次、切换账号不关（单实例）。
- relay_reward_client.dart：节日抽签端口 FestivalRewardClient 的中转实现 RelayRewardClient（人工决策见 domain/festival.dart）：POST /v1/rewards/<活动>/draw，用这个应用账号的设备密钥签名（安全存储 superxd_account 的 account.slot，没有这把密钥算没登录），请求体只有近 30 天打开过的天数；超时、请求记录与校时重发一次沿用 RelayClient，不重试；ACCOUNT_NOT_FOUND 与 UNAUTHORIZED 换成 FestivalNotSignedIn，其余给原因；parseFestivalDraw 把结果当外部输入校验。
- relay_diagnostic_account.dart：应用账号下的诊断包端口 DiagnosticAccountClient 的中转实现 RelayDiagnosticAccountClient（人工决策见 domain/diagnostic_upload.dart，协议见 server/README.md）：认领 POST /v1/account/diagnostics/<编号>/claim、列出 GET、删除 DELETE，用这个应用账号的设备密钥签名（没有这把密钥算没登录）；超时、请求记录与校时重发一次沿用 RelayClient，不重试；ACCOUNT_NOT_FOUND 与 UNAUTHORIZED 换成 DiagnosticNotSignedIn，回复逐项校验。
- account_seal.dart：应用账号登录时封装口令摘要的信封 sealAccountProof（一次性 X25519 与中转公钥 accountSealKey 协商、HKDF-SHA256、AES-256-GCM，附加数据绑定设备号；布局与服务端 account_keys.ts 一致，共用 server/test/vectors/account_seal_v1.json）。人工决策见 domain/app_account.dart；中转私钥只在服务器与开发者本机，换钥两边一起换。
- relay_app_account.dart：应用账号端口 AppAccountClient 的中转实现 RelayAppAccountClient（人工决策见 domain/app_account.dart，协议见 server/README.md）：每个教务账号一把单独的设备密钥（同私信身份的格式），登录成功才连同账号号存进安全存储的 superxd_account 命名空间（appAccountStorage，排除备份与迁移；存储键是教务身份的哈希 appAccountSlot，不出现学号）；登录请求 50 秒超时（中转代登录整次最多 40 秒），要验证码时这一次的密钥与挑战号留在内存里接着用；退出删服务端这把密钥（DELETE /v1/devices，连不上也删本机），注销先 DELETE /v1/account 再退出；中转的错误码换成 AppAccountException，响应逐项校验。
- relay_challenge_client.dart：挑战与积分端口 ChallengeClient 的中转实现 RelayChallengeClient（协议见 server/README.md「挑战与积分」）：用这个应用账号的设备密钥签名（AppAccountRef.slot 指向安全存储 superxd_account 里的那把，没登录不发请求），一局的回复放宽到 256KB（专家档一开局有 7 关的题面），回复逐项校验、看不懂按失败报；错误码换成 ChallengeException（RUN_ACTIVE 带编号、RUN_OVER 与 LEVEL_LOCKED 带现状、ACCOUNT_NOT_FOUND 与 UNAUTHORIZED 是没登录）。
- relay_client.dart：
  - relayBaseUrl：中转地址只来自构建参数 SUPERXD_RELAY，不写进代码；未配置时私信不可用。
  - RelayCode：错误码，与服务端 relay_error.ts 一致，另有 NETWORK、TIMEOUT、BAD_RESPONSE。
  - RelayTransport 传输端口，可按请求给超时与响应上限；HttpRelayTransport 经共用内核 domain/campus_http.dart 发，超时管到读完响应体（到点中断连接），默认 15 秒，长轮询为挂起时长加 10 秒；响应上限默认 responseLimit（64KB，最大的好友列表约 30KB），拉信箱按这次要的条数放宽（RelayClient.inboxLimit：每条按 360KB 算，单条密文 256KB 经 base64url 约 342KB），超了算 BAD_RESPONSE。经 _call 的请求（含节日抽签用的 RelayClient.request）都受这两条约束。
  - HttpRelayTransport 在断网、超时、响应格式不对时记 [RelayTransport] 日志：错误码、方法与路径、异常类型与完整堆栈，不写服务器地址与查询参数；往上只抛 RelayException 错误码。收消息的长轮询按后台请求发（background），它的断网与超时不在这里记，交给收取循环。
  - RelayClient：每个请求用设备私钥签名，没有会话令牌；收到 CLOCK_SKEW 按服务器时间校正并只重发这一次。request 用给定身份签名发任意路径（可另给超时与响应上限），给应用账号、挑战与节日抽签用；错误响应的其余字段放在 RelayException.detail。
  - 私信挂到应用账号 bindSocial（用应用账号的设备密钥签名，带私信密钥的凭证，可带接管）；好友列表 friends 解析成 RemoteFriend（换了设备的带新公钥与 movedFrom，公钥与设备号对不上算格式不对；keys 为真时每项都带公钥、响应放宽到 256KB）；ackMoves 确认换设备提示。
- social_store.dart：私信本机库（每个应用账号一份，文件见 social_spaces.dart，已排除备份）：profile、friend、message、invite 四张表，时间存 UTC ISO 字符串。第 2 版 profile 加 bound（已挂到应用账号；旧版升级上来是 0，打开时补挂一次）。好友换了设备时 relinkFriend 把好友连同会话改挂到新设备号与新公钥并写一条 friend_moved；新手机接管后 importFriend 补进服务器给的好友（名字先用 placeholderNickname，等对方发来昵称）。
- social_service.dart：SocialService 私信编排，是页面唯一入口。
  - 状态：loading、unavailable（未配置中转）、signedOut（没登录应用账号）、disabled（未开启）、elsewhere（这个账号的私信在另一台手机上）、ready、failed（打开时挂不上账号等，页面给重试 reopen）。
  - switchAccount 由组合根在同意协议与政策后、当前应用账号变化时调（main.dart 的 watchSocial）；切换后进行中的旧账号操作不再改界面状态，长轮询的旧一轮回来后让给新账号。
  - 挂账号：开启、打开时补挂（bound 为 0）、中转不认这台设备时都经 _bind 挂到当前应用账号；账号的私信在另一台手机上时转成 elsewhere，用户确认后 takeOver 接管（之后带 importRemote 刷新，补进服务器给的好友）；应用账号没了转成 signedOut 并调 accountGone（组合根让应用账号马上核一次）。forgetAccount 在注销应用账号后清掉这台手机上那个账号的私信。
  - 好友换了设备：核对好友列表时把 movedFrom 指着本机好友的改挂过来、确认提示，再给它发一条 profile（自己的昵称，失败只记日志）；收到不认识的发件人先核对一次；发送被拒 NOT_FRIEND 先核对，改挂了的报 FRIEND_MOVED（点重发即到新设备），还在旧号上的才算已解除。收到 profile 只认好友、验签后改昵称。
  - enable 生成身份、保存昵称、挂到当前应用账号；disable 先删服务端设备再清本机（中转已不认这台设备、或已被别的手机接管时照样清本机）。
  - 签名请求都经 _authorized：中转回 UNAUTHORIZED（从旧备份恢复、400 天不活跃被清、被别的手机接管）时重新挂账号一次再重放这一次，几个请求同时遇到时共用一次；挂账号得到在另一台手机上或账号没了就转状态、不重放。
  - createInvite / redeem 扫码加好友；refresh 拉信箱、解密验签、入库后再确认删除；send / retry 发送卡片；removeFriend、setRemark、markRead、deleteMessage。
  - polling 为真时就绪后在前台持续长轮询（每次挂起 longPollWait 25 秒，有新消息立即返回），回到前台先拉一次并核对好友，进入后台不再发起；网络失败指数退避（2 秒起、上限 60 秒，实际等待在这一档的一半到整档之间随机，随机源可注入，[人工决策] 在 liveRetryDelay），空响应快于 5 秒时等满 5 秒防空转；断网与超时连续失败到 liveFailureLimit（5 次）那次才记一条错误，之前只记不算错误的一行（[人工决策] 在 liveFailureLimit）。应用里开启，测试关闭。页面不再自己定时拉取。

# 关键规则

- 扫码即成为好友（人工决策见 social_service.dart 的 redeem 与服务端 pairing.service.ts）。二维码 5 分钟有效、期内可被多人扫，新建即作废旧的，离开出示页即作废。
- 信任链：扫码方从二维码直接拿到出示方公钥；出示方收到的问候要同时满足“设备号由问候里的签名公钥推出”“问候签名有效”“凭证由本机出示过的邀请私钥签出且绑定扫码方设备号”，服务器无法伪造好友。例外是换手机（11-14 用户选定的接管）：好友的新公钥与新手机的好友名单由服务器给，这一步信任服务器，靠会话里的「对方换了设备」让人看得到，新公钥仍须与设备号对得上。
- 收到的任何消息都是外部输入：解密、核对消息头（发送方、收件人、消息号格式）、验签、卡片解码（decodeShareCard）任一步失败就丢弃并记日志，照样确认删除，避免反复拉取坏消息。非好友发来的卡片同样丢弃。
- 收发幂等：发送消息号即服务端去重键，重发沿用同一号；收到的消息按消息号入库，重复投递只算一次。
- 不自动重试：发送失败记错误码，由用户点重发；例外只有时钟偏差校正后的一次重发，与中转不认这台设备（UNAUTHORIZED）时重新挂账号后的一次重放（[人工决策] 在 social_service.dart 的 _authorized）。好友换了设备时发送被拒，改挂后报 FRIEND_MOVED 由用户点重发，不自动重发。收消息的长轮询是持续的接收通道，失败后退避继续，不属于重试用户操作。应用被杀时停在“发送中”的消息启动后改为失败。
- 上限：好友 500；每个好友保留最近 200 条；邀请记录保留 31 天（覆盖信箱 30 天保留期内迟到的问候）；单条密文 256KB（服务端判定）。
- 隐私：私钥只在安全存储；服务端只见设备号、私信设备属于哪个应用账号（因此知道哪些应用账号互为好友，用户 11-14 知情选定）、好友关系、密文大小与时间；昵称、课表、界面、作品链接都在密文里，换手机后补昵称的 profile 也在密文里。视频卡片不带媒体直链与封面。
- 身份丢失（安全存储被清）时清空本机私信库回到未开启，旧会话已无法解密。

# 测试

- social_protocol_test.dart（与服务端共用测试向量、信封、二维码、应用账号信封、挂账号凭证）、share_card_test.dart、social_service_test.dart（含「私信跟着应用账号」一组：没登录、每账号一份、旧版第 1 版库并入与升级、换手机接管与再接管、发送被拒后改挂、注销、账号没了）、social_ui_test.dart（含没登录与在另一台手机上的卡片、接管确认、会话里的换设备提示）；节日抽签 relay_reward_client.dart 在 festival_test.dart（经 fake_relay.dart 验签、用应用账号的密钥签名）；应用账号 relay_app_account.dart 在 app_account_test.dart；诊断包 relay_diagnostic_account.dart 在 diagnostic_upload_test.dart。
- fake_relay.dart 是按协议 v1 规则验签的内存假中转（含应用账号登记 signIn、挂账号与接管、好友公钥与 movedFrom）。服务端：cd server 后 npm test（Vitest，需 docker-compose.test.yml 起的 MySQL 与 Redis）。
- 手动入口：tool/verify_social.dart（两个真实客户端经真实中转联调，只用合成数据，运行方式见文件头；挂应用账号要真实教务，这一个请求在本地截下，见文件头）。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/social server/src
- 标记位于：前台长轮询收消息、不接推送（social_service.dart 的 startPolling）、自建加密中转与地址不写死（relay_client.dart）、身份跟设备走（social_service.dart，11-14 由同处「私信跟着应用账号」与注销一并删除两条取代）、中转不认设备时重新注册并重放一次（social_service.dart 的 _authorized）、扫码即成为好友（social_service.dart 的 redeem 与服务端 pairing.service.ts）、课表一次性快照与首批卡片（domain/share_card.dart）。
