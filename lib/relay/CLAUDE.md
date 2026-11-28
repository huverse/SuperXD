# relay 自建中转的签名请求与应用账号

定位：自建中转（server 目录，NestJS）的签名请求，以及应用账号与它签名的各个中转客户端（11-17 从 social 拆出，人工决策在 test/project_structure_test.dart 的分层表）。只依赖 domain；各客户端实现 domain 的端口，由组合根注入，application 与 page 不直接依赖。私信自己的接口、身份库与本机库在 social（依赖本层的签名请求与应用账号的设备密钥）；不签名的设备侧中转客户端（更新清单、开发者的话、灰度配置、健康回报、诊断包上传、字体包）在 device。协议与限额见 server/README.md。

# 文件职责

- relay_crypto.dart：签名请求共用的协议 v1 密码学，与服务端 relay_crypto.ts 逐字节一致，双端共用 server/test/vectors/protocol_v1.json。
  - 设备身份 RelayIdentity：Ed25519 签名密钥加 X25519 加密密钥；设备号是签名公钥 sha256 的前 16 字节（base64url）。应用账号的设备密钥与私信身份都是它。
  - 请求签名原文 requestCanonical、服务器给奖品信封签名的原文 rewardPrizeCanonical、「账号已注销」证明的原文 accountDeletedCanonical；decodeBase64UrlNoPad 不合格抛 RelayCryptoException。
- relay_client.dart：
  - relayBaseUrl：中转地址只来自构建参数 SUPERXD_RELAY，不写进代码；未配置时私信、应用账号与各签名客户端都不可用。
  - RelayCode：错误码，与服务端 relay_error.ts 一致（私信的码也在这里，私信层另给页面起同值的 SocialCode），另有 NETWORK、TIMEOUT、BAD_RESPONSE。
  - RelayTransport 传输端口，可按请求给超时与响应上限；HttpRelayTransport 经共用内核 domain/campus_http.dart 发，超时管到读完响应体（到点中断连接），默认 15 秒，长轮询为挂起时长加 10 秒；响应上限默认 responseLimit（64KB，最大的好友列表约 30KB），拉信箱按条数放宽（见 social/social_relay.dart），超了算 BAD_RESPONSE。
  - HttpRelayTransport 把每条回复头交给组合根给的 RolloutSignals（灰度版本号 x-sxd-config、x-sxd-targets，人工决策见 domain/rollout.dart），RelayResponse 带回复头。
  - HttpRelayTransport 在断网、超时、响应格式不对时记 [RelayTransport] 日志：错误码、方法与路径、异常类型与完整堆栈，不写服务器地址与查询参数；往上只抛 RelayException 错误码。持续接收通道的长轮询按后台请求发（background），它的断网与超时不在这里记，交给调用方的接收循环。
  - RelayClient：request 用给定的设备身份签名发任意路径（可另给超时、响应上限与 background），没有会话令牌；exchange 同它、另可加请求头并拿整条回复（304 算成功，给条件请求）；收到 CLOCK_SKEW 按服务器时间校正并只重发这一次；收到 ACCOUNT_DELETED 要验回复里的 proof（服务器对这把密钥的设备号与这次请求随机数的签名），没有或验不过记 errorType=signature、当 NETWORK 抛，调用方什么也不删（[人工决策] 在 _deletionProven）；错误响应的其余字段放在 RelayException.detail。register 与 deleteDevice 是设备登记（POST、DELETE /v1/devices）。每个客户端各持一个 RelayClient（各自的校时偏差）。
  - 服务器在线签名钥的公钥内置在 relayServerKeys（[人工决策] 在常量上：签好友公钥、奖品信封与「账号已注销」三类，域前缀区分）；verifyRelaySignature 任一把验过即可；各客户端与 SocialService 的 serverKeys 可换成测试钥。
- relay_egress.dart：出口策略 EgressRelayTransport（审查 P2-2）：给一项联网服务（domain/network_policy.dart 的 NetworkService）用的签名传输套一层，发请求前问联网策略，不许就在本机拒掉、不交给传输，当连不上（NETWORK）抛、记一行 [RelayEgress] action=deny ... errorType=policy（照理走不到，出现了说明上层漏了判断）。属于哪项服务由组合根接线时给（app_services.dart 的 RelayWiring.transportFor），传输本身不认识具体功能。
- app_account_vault.dart：应用账号设备密钥的安全存储 AppAccountVault：这台设备一把设备密钥，连同账号号与用户名存进 superxd_account 命名空间（appAccountStorage，排除备份与迁移；键是 appAccountSlot）；SecureAppAccountVault 用系统安全存储，MemoryAppAccountVault 供测试。keyOf 读某个应用账号的那把：槽是一台设备共用的，账号号对不上的当没有（11-28 审查 F01：换过账号后旧引用会读到新账号的密钥），签名请求与私信挂账号都经它读。
- account_relay.dart：用应用账号的设备密钥签名访问中转的共用调用 AccountRelay（审查 P2-3，以前六个客户端各抄一份）：signedCall 读这个账号在本机的那把密钥（没有就抛 missingKey、不发请求）、签名发出、中转的错误码按 RelayErrors 换成本模块的异常；回复回来时这个账号在本机的密钥已经换了（换了账号、退出、同一账号重新登录换了新密钥，按设备号比）就不交给调用方（signedCall 算没登录、send 与 exchange 为空，11-28 复核 F01），出错的回复照常抛；signedWith 用给定的密钥签名（注册、登录、扫码出示的新密钥）；send 没有密钥返回空、错误码原样抛（给要按错误码返回结果的点名与抽签的账号太新）；exchange 同 send、另可加请求头拿整条回复（点名的条件请求）。RelayErrors 把没登录（ACCOUNT_NOT_FOUND、UNAUTHORIZED）、连不上（NETWORK、TIMEOUT）、限流与其余四类的分法写在一处，模块只给换成什么，自己的业务码放 codes。每个客户端各持一个（各自的校时偏差）。
- account_seal.dart：应用账号的密码与恢复码发出前封装的信封 sealAccountSecrets（第 2 版：一次性 X25519 与中转公钥 accountSealKey 协商、HKDF-SHA256、AES-256-GCM，信封带钥号 accountSealKeyId（公钥 sha256 的前 8 字节），附加数据绑定钥号与设备号；布局与服务端 account_keys.ts 一致，共用 server/test/vectors/account_seal_v2.json）。当初中转是明文 HTTP，不封装就会被同一网络里的人看到；11-18 起走 HTTPS 后照旧封装（纵深防御，中转的接入层与日志也碰不到明文）；中转私钥只在服务器与开发者本机。服务器按钥号可以同时认几把，换钥先加服务器、再发换了公钥的版本（步骤见 server/README.md「部署」应用账号一条），这里只放现用的一把。
- relay_app_account.dart：应用账号端口 AppAccountClient 的中转实现 RelayAppAccountClient（人工决策见 domain/app_account.dart，协议见 server/README.md「应用账号」）。注册、登录、用恢复码重设都先生成一把新密钥，用户名与封装好的秘密一起发出，成功才存本机；扫码登录出示时的密钥只放内存、按票据号各记一把（最多 4 张），批准了才存；离开出示页、刷新、改用别的方式登录时立即作废，在路上的轮询回来说批准了也不存、不登录，并删掉批准时多登记的那台设备（11-28 审查 F04）；批准后的核对、写入与写后复核在本机密钥的写入队列里一次做完，排队或正在写时被作废就不写、已写的放回写之前那条（11-28 复核 F04）；本机密钥的写入与删除排成一个队，查看账号与退出只删发请求的那把（审查 F03）；出示时带上组合根注入的机型 deviceModel（去掉控制字符、最多 64 个字符，读不出不带），离开出示页用那把临时密钥作废票据（cancelJoin，批准过或没出示过不发）；登录着的设备改密码、换恢复码、批准前看请求方（inspectJoin，机型与属地逐项校验）、批准登录码；dropLegacy 删掉 11-15 以前每个教务账号一把的旧密钥（键 account.* ）并交出把手；退出删服务端这把密钥（DELETE /v1/devices，连不上也删本机），注销先 DELETE /v1/account 再退出；中转的错误码换成 AppAccountException（ACCOUNT_DELETED 是 deleted，查看账号时同 notSignedIn 删本机记录；它要带服务器签名才认，见 RelayClient），响应逐项校验。
- relay_reward_client.dart：节日抽签端口 FestivalRewardClient 的中转实现 RelayRewardClient（人工决策见 domain/festival.dart）：POST /v1/rewards/<活动>/draw，用这个应用账号的设备密钥签名（安全存储 superxd_account 里 AppAccountRef.slot 指的那把，没有这把密钥算没登录），请求体只有近 30 天打开过的天数；不重试；ACCOUNT_NOT_FOUND 与 UNAUTHORIZED 换成 FestivalNotSignedIn，ACCOUNT_TOO_NEW 换成结果 FestivalTooNew（带 eligibleAt），sold_out 换成 FestivalSoldOut（发完为止的这一批领完了，11-18 起），其余给原因；抽中的奖品是服务器用这台设备的 box 公钥封装、另接服务器签名的 sealed（请求体带 seal: 2 要第 2 版），openRewardPrize 只认第 2 版：先用 relayServerKeys 验签（绑定活动与设备号），验过才用那把设备密钥解开，验不过、打不开都当格式不对、不给内容（[人工决策] 在函数上；与服务端 reward_seal.ts 共用 server/test/vectors/reward_prize_v2.json），parseFestivalDraw 把结果与解开的奖品当外部输入校验（11-16 起认 ineligible）；status 是 GET /v1/rewards/<活动>（信里的「领取」先问，仅本机时带 levels=0），parseRewardStatus 逐项校验。
- relay_diagnostic_account.dart：应用账号下的诊断包端口 DiagnosticAccountClient 的中转实现 RelayDiagnosticAccountClient（人工决策见 domain/diagnostic_upload.dart）：认领 POST /v1/account/diagnostics/<编号>/claim、列出 GET、删除 DELETE，用这个应用账号的设备密钥签名（没有这把密钥算没登录）；不重试；ACCOUNT_NOT_FOUND 与 UNAUTHORIZED 换成 DiagnosticNotSignedIn，回复逐项校验。
- relay_pass_client.dart：积分时长券端口 PassClient 的中转实现 RelayPassClient（人工决策见 domain/pass.dart 与服务端 src/modules/pass/pass.service.ts）：清单 GET /v1/app/passes 免签名、不带标识，自己的券 GET /v1/passes 与购买 POST /v1/passes/<编号>/buy 用这个应用账号的设备密钥签名；回复上限 16KB、逐项校验，错误码换成 PassException（POINTS_SHORT 带价格、PASS_UNAVAILABLE、没登录、限流与连不上分开）。
- relay_unlock_client.dart：解锁端口 UnlockClient 的中转实现 RelayUnlockClient（规则见服务端 src/modules/unlock/unlock_rules.ts）：GET /v1/unlocks 与 POST /v1/unlocks/<编号>/buy，用这个应用账号的设备密钥签名，回复上限 16KB、逐项校验（等级 0–5、编号合规、不超过 rolloutUnlockLimit 个）；错误码换成 UnlockException（POINTS_SHORT 带价格、UNLOCK_UNAVAILABLE、ACCOUNT_NOT_FOUND 与 UNAUTHORIZED 是没登录）。
- relay_flag_target_client.dart：灰度点名端口 RolloutTargetClient 的中转实现 RelayFlagTargetClient（人工决策见 domain/rollout.dart 文件头 11-16 那条，服务端 src/modules/flag_target）：GET /v1/flags/mine，用这个应用账号的设备密钥签名，回复上限 32KB、经 decodeRolloutTargets 逐项校验；没这把密钥、ACCOUNT_NOT_FOUND 与 UNAUTHORIZED 为空（没登录），其余错误与看不懂的回复抛 RolloutException；11-20 起带上次的版本号发条件请求，304 给出没变。
- relay_challenge_client.dart：挑战与积分端口 ChallengeClient 的中转实现 RelayChallengeClient（协议见 server/README.md「挑战与积分」）：用这个应用账号的设备密钥签名（没登录不发请求），一局的回复放宽到 256KB（专家档一开局有 7 关的题面），回复逐项校验、看不懂按失败报；开门与终章各一个请求（门上的数、全部碎片之和）；错误码换成 ChallengeException（RUN_ACTIVE 带编号、RUN_OVER 与 LEVEL_LOCKED 带现状、ACCOUNT_NOT_FOUND 与 UNAUTHORIZED 是没登录）。关卡图按服务端模板的规则核对（编号不重复、引用的关都在、不指向自己、每关的碎片只交给一关、不成环；首页缩略图的边同样），不合格当看不懂。

# 关键规则

- RelayException 与 RelayCode 不出本层（私信层另起同值的 SocialCode 给页面）：各客户端把中转的错误码换成本模块在 domain 登记的异常（经 account_relay.dart 的 RelayErrors），application 与 page 只认那些异常。新的账号签名客户端一律经 AccountRelay 发，不再自己读密钥、自己接 RelayException。
- 不自动重试：只有时钟偏差校正后的一次重发（RelayClient）；中转不认私信设备时的那次重放在 social（SocialService 的 _authorized）。
- 联网策略两道：上层（组合根的钩子按 NetworkService、节日与灰度点名等服务里读 online）照旧先判断，不起无用的请求；签名请求的出口再兜底（relay_egress.dart），新加的签名客户端一律经 RelayWiring.transportFor 拿传输。用应用账号身份发的点名与诊断包认领归 appAccount。不签名的设备侧中转客户端（device）不经这里，仍只靠上层。
- 应用账号的设备密钥只在系统安全存储（superxd_account，排除备份与迁移）；业务库与日志不存密钥、密码与恢复码。
- 回复一律是外部输入：逐项校验，看不懂的按失败报、不猜；会触发不可逆动作的两类回复（奖品、「账号已注销」）要服务器签名才认。

# 测试

- 签名请求与共用向量（请求签名、「账号已注销」的证明、应用账号信封）在 social_protocol_test.dart；传输的响应上限在 campus_http_test.dart。
- relay_errors_test.dart：六个账号签名客户端把中转错误码换成本模块异常的整张表（类型、分类与文案，没这把密钥不发请求、各自的响应上限），抽共用调用前后同一张表都过；出口策略拒掉的不交给传输、客户端当连不上。组合根里出口一次也没拒过、仅本机绕过钩子直接调也出不去在 composition_root_test.dart。
- 节日抽签 relay_reward_client.dart 在 festival_test.dart（经 fake_relay.dart 验签、用应用账号的密钥签名）；应用账号 relay_app_account.dart 在 app_account_test.dart；诊断包 relay_diagnostic_account.dart 在 diagnostic_upload_test.dart；解锁 relay_unlock_client.dart 在 unlock_test.dart；时长券 relay_pass_client.dart 在 pass_test.dart；灰度点名 relay_flag_target_client.dart 在 rollout_test.dart；挑战 relay_challenge_client.dart 在 challenge_test.dart；接起来的样子在 composition_root_test.dart。
- fake_relay.dart 是按协议 v1 规则验签的内存假中转（应用账号登记 signIn、私信与好友；serverSign 用服务器在线签名的测试钥签，serverSeedOverride 模拟网络上的人伪造）。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/relay server/src
- 标记位于：自建加密中转与地址不写死、好友公钥与两类关键回复要服务器签名（relay_client.dart 的 relayBaseUrl、relayServerKeys 与 _deletionProven）、奖品信封只认第 2 版（relay_reward_client.dart 的 rewardSignedSealVersion）。
