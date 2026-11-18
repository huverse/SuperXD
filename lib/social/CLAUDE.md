# social 功能性私信

定位：好友与功能性私信（只有分享卡片，没有文字聊天），11-14 起跟着当前应用账号（人工决策见 social_service.dart 文件头）：每个应用账号在这台手机上一份，没登录应用账号时停用。依赖 domain 与 relay（签名请求、设备身份 RelayIdentity 与应用账号的设备密钥库，11-17 起应用账号与它签名的中转客户端都在 lib/relay）；页面经 SocialService 使用（错误码只认 SocialCode，不依赖 relay），百宝箱经组合根注入的回调使用。退出应用账号、切换或退出教务都不清本机。中转服务端在仓库 server 目录（NestJS），协议与限额见 server/README.md。

# 文件职责

- social_crypto.dart：协议 v1 里私信自己的密码学，与服务端 relay_crypto.ts 逐字节一致，双端共用 server/test/vectors/protocol_v1.json（含服务器给好友公钥签名的原文 friendKeysCanonical）。私信身份是 relay/relay_crypto.dart 的设备身份 RelayIdentity。
  - 对方的公开身份 PeerKeys（设备号由签名公钥推出）、邀请凭证原文 inviteProofCanonical、私信设备挂到应用账号的凭证原文 socialBindCanonical（共用向量 socialBind）。
  - 信封 sealEnvelope / openEnvelope：明文 gzip 后由发送方签名，再用一次性 X25519 与收件人协商，HKDF-SHA256 派生 AES-256-GCM 密钥加密，附加数据绑定收件人设备号；解压上限 1MB。验签 verifyOpened 在确认发送方后进行。
- invite_code.dart：好友二维码内容 InviteCode（SXD1F: 前缀）：邀请号、邀请私钥种子、出示方公钥与昵称、过期时刻，二进制布局转 Base45（RFC 9285），按 QR 字母数字模式编码；validNickname 昵称规则（1–20 字，无首尾空白与控制字符）。
- identity_vault.dart：私信身份私钥种子的存放 IdentityVault（每个应用账号一项，键由 social_spaces.dart 定；另记旧版私信归哪个账号 legacyOwner）；SecureIdentityVault 用系统安全存储（命名空间 superxd_social，已排除云备份与设备迁移）；MemoryIdentityVault 供测试。
- social_spaces.dart：每个应用账号一份私信 SocialSpaces：本机库与身份的键。旧版留下的设备级私信（库 social.db、身份 identity）归这台手机上第一个用私信的应用账号（legacyOwner），其余账号库在数据库目录的 social/<账号号>.db、身份 identity.<账号号>（social 文件夹整个排除备份，两份备份规则与 iOS 的 excludeFromBackup 都有，test/legal_page_test.dart 守护）；库只开一次、切换账号不关（单实例）。existing 只找已有的那一份（清注销了的账号用：不认领旧版私信、不新建库）。
- social_relay.dart：私信经中转的接口 SocialRelay（签名、校时重发一次与「账号已注销」的核对在 relay 层的 RelayClient，这里只管路径与回复）：
  - 私信挂到应用账号 bindSocial（用应用账号的设备密钥签名，带私信密钥的凭证，可带接管）；好友列表 friends 解析成 RemoteFriend（换了设备的带新公钥与 movedFrom，公钥与设备号对不上、没有服务器签名或验不过都算格式不对，服务器公钥见 relay/relay_client.dart 的 relayServerKeys；keys 为真时每项都带公钥、响应放宽到 256KB）；ackMoves 确认换设备提示。
  - 邀请 createInvite、revokeInvite、扫码 redeem；发送 send；拉信箱 fetch（响应上限按这次要的条数放宽 inboxLimit：每条按 360KB 算，单条密文 256KB 经 base64url 约 342KB；带 wait 是长轮询，按后台请求发）与 ack；removeFriend；deleteDevice 关闭私信时删服务端设备。
- social_store.dart：私信本机库（每个应用账号一份，文件见 social_spaces.dart，已排除备份）：profile、friend、message、invite 四张表，时间存 UTC ISO 字符串。第 2 版 profile 加 bound（已挂到应用账号；旧版升级上来是 0，打开时补挂一次）。好友换了设备时 relinkFriend 把好友连同会话改挂到新设备号与新公钥并写一条 friend_moved；新手机接管后 importFriend 补进服务器给的好友（名字先用 placeholderNickname，等对方发来昵称）。
- social_service.dart：SocialService 私信编排，是页面唯一入口。
  - 状态：loading、unavailable（未配置中转）、signedOut（没登录应用账号）、disabled（未开启）、elsewhere（这个账号的私信在另一台手机上）、ready、failed（打开时挂不上账号等，页面给重试 reopen）、offline（仅本机时停着，人工决策见 domain/network_policy.dart 的 11-16 22:24:59 那条）。
  - setOffline 由组合根跟着联网偏好调（watchSocial）：停着不收发、不挂账号，账号与本机记录都留着；改回联网按原账号重新打开。
  - switchAccount 由组合根在同意协议与政策后、当前应用账号变化时调（app_lifecycle.dart 的 watchSocial）；切换后进行中的旧账号操作不再改界面状态，长轮询的旧一轮回来后让给新账号。
  - 挂账号：开启、打开时补挂（bound 为 0）、中转不认这台设备时都经 _bind 挂到当前应用账号；账号的私信在另一台手机上时转成 elsewhere，用户确认后 takeOver 接管（之后带 importRemote 刷新，补进服务器给的好友）；应用账号没了转成 signedOut 并调 accountGone（组合根让应用账号马上核一次）。forgetAccount 在注销应用账号、启动清 11-15 以前的旧账号时清掉这台手机上那个账号的私信（没用过私信的什么也不动）。
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
- 隐私：私钥只在安全存储；服务端只见设备号、私信设备属于哪个应用账号（因此知道哪些应用账号互为好友，用户 11-14 知情选定）、好友关系、密文大小与时间；昵称、课表、作品链接都在密文里，换手机后补昵称的 profile 也在密文里。视频卡片不带媒体直链与封面。
- 身份丢失（安全存储被清）时清空本机私信库回到未开启，旧会话已无法解密。

# 测试

- social_protocol_test.dart（与服务端共用测试向量、信封、二维码、应用账号信封、挂账号凭证、「账号已注销」的证明）、share_card_test.dart、social_service_test.dart（含「私信跟着应用账号」一组：没登录、每账号一份、旧版第 1 版库并入与升级、换手机接管与再接管、发送被拒后改挂、注销、账号没了）、social_ui_test.dart（含没登录与在另一台手机上的卡片、接管确认、会话里的换设备提示）；应用账号与它签名的中转客户端的测试登记在 lib/relay/CLAUDE.md。
- fake_relay.dart 是按协议 v1 规则验签的内存假中转（含应用账号登记 signIn、挂账号与接管、好友公钥与 movedFrom；serverSign 用服务器在线签名的测试钥签，serverSeedOverride 模拟网络上的人伪造）。服务端：cd server 后 npm test（Vitest，需 docker-compose.test.yml 起的 MySQL 与 Redis）。
- 手动入口：tool/verify_social.dart（两个真实客户端经真实中转联调，只用合成数据，运行方式见文件头；挂应用账号那一个请求在本地截下，免得在线上留下合成的应用账号，见文件头）。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/social lib/relay server/src
- 标记位于：前台长轮询收消息、不接推送（social_service.dart 的 startPolling）、自建加密中转与地址不写死（relay/relay_client.dart）、身份跟设备走（social_service.dart，11-14 由同处「私信跟着应用账号」与注销一并删除两条取代）、中转不认设备时重新注册并重放一次（social_service.dart 的 _authorized）、扫码即成为好友（social_service.dart 的 redeem 与服务端 pairing.service.ts）、课表一次性快照与首批卡片（domain/share_card.dart）。
