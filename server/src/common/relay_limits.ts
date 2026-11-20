// 中转服务的全部上限与保留期集中在这里；改动须同步 README 的“上限与保留”，以及客户端索引（私信见 lib/social/CLAUDE.md，代签见 lib/toolbox/CLAUDE.md 与根 CLAUDE.md 的数据保留）。

// HTTP 服务端的超时（src/common/http_server.ts 设到 Node 的 http.Server 上，不用 Node 默认值）：
// 收完一个请求（头加体）最多 httpRequestTimeoutMs：最大的请求体是 24MB 的诊断包，客户端整次最多 5 分钟（lib/device/relay_diagnostic_upload.dart），这里多留 30 秒；
// 长轮询挂起的是回复、不算在内。收完请求头最多 httpHeadersTimeoutMs。空闲的保活连接留 httpKeepAliveTimeoutMs：要长过客户端自己关空闲连接的时刻
// （Dart HttpClient 默认 15 秒）与以后前置代理的上游保活（Nginx 默认 60 秒），不然两边一关一用撞上会被重置；请求头超时比它多 1 秒（Node 的老建议，防保活连接上的下一个请求被误判超时）。
export const httpRequestTimeoutMs = 330_000;
export const httpKeepAliveTimeoutMs = 65_000;
export const httpHeadersTimeoutMs = 66_000;

// 请求签名：时间戳与服务器相差超过 5 分钟拒绝；随机数 10 分钟内不得重复（覆盖时间窗两侧）。
export const clockSkewMs = 5 * 60 * 1000;
export const nonceTtlSeconds = 10 * 60;

// 邀请：二维码 5 分钟有效，有效期内可被多人扫；每台设备同时只有一个有效邀请，新建即作废旧的。
export const inviteTtlSeconds = 5 * 60;

// 好友：每台设备最多 500 个。
export const friendLimit = 500;

// 信箱：单条密文不超过 256KB；每台设备待取最多 1000 条，超出拒收，由发送方提示稍后再发。
export const envelopeMaxBytes = 256 * 1024;
export const mailboxLimit = 1000;
// 未取走的消息 30 天后删除；取走并确认后立即删除。
export const messageTtlDays = 30;
// 长轮询：没有消息时最多挂起 25 秒（低于客户端与常见代理的 30 秒超时）；每设备同时最多 2 个挂起请求（再来就让最早的先返回），
// 每个实例最多 20000 个（超出时立即返回空，由客户端按最小间隔重试），挂起只占内存与一个空闲连接，不占数据库连接。
export const longPollMaxSeconds = 25;
export const longPollPerDevice = 2;
export const longPollPerInstance = 20000;
// 单次拉取最多 50 条，确认最多 100 条。
export const fetchLimit = 50;
export const ackLimit = 100;

// 发送限流：每设备每分钟 30 条、每天 500 条（按 UTC 日界，只防刷不涉业务日）。
export const sendPerMinute = 30;
export const sendPerDay = 500;
// 注册限流：每个来源 IP 每小时 20 台新设备。
export const registerPerHour = 20;
// 兑换邀请限流：每设备每分钟 10 次，防止穷举。
export const redeemPerMinute = 10;
// 私信挂到应用账号（含接管）：每把应用账号密钥每小时 30 次（正常只在开启私信、重新登录与换手机时各一次）。
export const socialBindPerHour = 30;

// 代签凭据包：单条不超过 2KB，取件号 10 分钟有效。
// [人工决策-2026-10-07 17:00:15] 限流采用极度宽松策略：同一 IP 每小时提交 1000 个、取件 3000 次。校园网出口多为 NAT，
// 一栋楼甚至一所学校共用一个 IP，原来的每小时 20 次会让同学互相挡住；取件号是 96 位随机数且一次性、10 分钟过期，
// 穷举不可行，限流只防脚本刷库撑爆存储（包本身 2KB；10 分钟过期即取不到，清理任务每 10 分钟一轮，最迟约 20 分钟内删掉）。
// 作废（出示方换码时作废上一张）与取件同一宽松档。
export const chaoxingPackMaxBytes = 2 * 1024;
export const chaoxingPackTtlSeconds = 10 * 60;
export const chaoxingPackPerHour = 1000;
export const chaoxingPackPickupPerHour = 3000;
export const chaoxingPackRevokePerHour = 3000;
// 代签接口的请求体上限：包 2KB 经 base64url 约 2.7KB，外加字段，8KB 足够；不签名的接口不该吃全局 400KB 的上限。
export const chaoxingRequestMaxBytes = 8 * 1024;

// 应用更新：客户端每天最多自动查一次清单，手动检查不限；同一 IP 每小时清单 600 次、安装包请求 300 次
// （含断点续传的分段请求；校园网出口多为 NAT，与代签同样放宽，只防脚本刷流量）。
// 安装包约 100MB，每个实例同时最多 32 个下载，超出回 503 让客户端稍后再试，保护带宽与连接。
// 清单文件超过 128KB 视为放错文件，拒绝读取（明文加三个架构的签名信封，更新说明写满 4000 字也不到 70KB；与 tool/release_manifest.dart 一致）。
export const appReleasePerHour = 600;
export const appFilePerHour = 300;
export const appDownloadsPerInstance = 32;
export const appReleaseFileMaxBytes = 128 * 1024;

// 开发者的话：维护者写的信由流水线放进发布目录（developer_notes.json），客户端启动与回到前台时看一眼（间隔不到一小时不联网），
// 同一 IP 每小时 600 次（与查清单同档）。只下发最近 30 封，标题不超过 40 字、正文不超过 4000 字（与客户端 lib/domain/developer_note.dart 一致），
// 文件超过 1MB 视为放错文件，拒绝读取（明文一份加签名载荷一份，30 封写满也不到 900KB；与 tool/developer_notes.dart 及客户端的响应上限一致）。
export const developerNotesPerHour = 600;
export const developerNoteLimit = 30;
export const developerNoteTitleMax = 40;
export const developerNoteBodyMax = 4000;
// 一封信最多带这么多个附件（如领取红包，人工决策见 src/modules/reward/reward_odds.ts 的 11-16 那条），与客户端 developerNoteAttachmentMax 一致。
export const developerNoteAttachmentMax = 4;
export const developerNotesFileMaxBytes = 1024 * 1024;

// 灰度配置（人工决策见客户端 lib/domain/rollout.dart）：维护者本机签好两份放进发布目录（tool/rollout_config.dart 与 rollout_publish.sh，第 1 版 rollout.json、第 2 版 flags.json），
// 客户端同意协议与政策后、回到前台时看一眼（间隔不到一小时不联网），同一 IP 每小时 600 次（与开发者的话同档）。最多 200 个开关、每个 20 档，
// 明文加签名载荷两份也远不到 64KB，文件超过 64KB 视为放错文件，拒绝读取（与客户端 lib/device/relay_rollout_feed.dart 的响应上限一致）。
export const rolloutConfigPerHour = 600;

// 分批更新的健康回报与意见反馈（人工决策见 src/modules/app_health/app_health_rules.ts）：都匿名、不带账号与设备号，按来源限流。
// 健康回报每台每天最多一次（客户端），中转每个来源每小时最多 healthReportPerSourcePerHour 次（校园网 NAT 下一个出口很多人）；只收最近 healthReportMaxAgeDays 天的。
// 自动暂停：最近 healthWindowDays 天里新旧两版各至少 healthMinSamples 份，新版致命率超过旧版的 healthPauseRatio 倍且高出 healthPauseMargin 才停。
// 意见每个来源每小时 feedbackPerSourcePerHour 条、每条最多 feedbackTextMax 字。健康汇总与意见保留 healthKeepDays 天，暂停记录保留 healthPauseKeepDays 天。
export const healthReportPerSourcePerHour = 60;
export const healthReportMaxAgeDays = 7;
export const healthWindowDays = 3;
export const healthMinSamples = 50;
export const healthPauseRatio = 2;
export const healthPauseMargin = 0.05;
export const feedbackPerSourcePerHour = 5;
export const feedbackTextMax = 200;
export const healthKeepDays = 90;
export const healthPauseKeepDays = 180;
export const rolloutFlagLimit = 200;
export const rolloutStageLimit = 20;
export const rolloutFileMaxBytes = 64 * 1024;

// 电影院的片源规则包（人工决策见客户端 lib/toolbox/cinema/cinema_service.dart 文件头）：维护者本机签好放进发布目录（tool/cinema_rules.dart 与 cinema_publish.sh），
// 客户端打开电影院时拉（两次至少隔一小时），同一 IP 每小时 600 次（与灰度配置同档）。规则包载荷上限 256KB，加信封与 base64 远不到 512KB，
// 文件超过 512KB 视为放错文件，拒绝读取（与客户端 lib/device/relay_cinema_feed.dart 的响应上限一致）。
export const cinemaRulesPerHour = 600;
export const cinemaFileMaxBytes = 512 * 1024;

// 节日抽奖（概率模型与要求设备签名的人工决策见 src/modules/reward/reward_odds.ts）：同一来源每小时 3000 次（校园网 NAT 共用出口，同代签取件的宽松档），
// 每台设备每小时 10 次（一个应用账号一次活动只抽一次、重复请求返回同一结果，正常客户端只在没连上时补抽；按设备计数让刷请求的设备先被自己的额度挡住）；
// 刷号的成本是应用账号的注册限流（accountRegisterPerSourcePerHour）与下面的账号年龄。活动行在进程内缓存 60 秒（建活动、改时间最迟一分钟生效）；活动结束 30 天后连同奖品与抽签记录删除。
// 账号建立满几天才能抽由每个活动自己定（reward_campaign.min_account_days，人工决策见 reward_odds.ts 的 11-16 那条），建活动不写时用 rewardDefaultMinAccountDays
// （注册用户名谁都能建号，挡住批量新建的账号抽红包；补偿红包可设 0）。名单活动的名单每次导入最多 rewardAudienceImportMax 个用户名。
// 查一个活动的状态（信里的「领取」按钮先问能不能领）每台设备每小时 rewardStatusPerDevicePerHour 次。
export const rewardDefaultMinAccountDays = 7;
export const rewardMinAccountDaysMax = 3650;
export const rewardAudienceImportMax = 100_000;
export const rewardStatusPerDevicePerHour = 120;
export const rewardDrawPerHour = 3000;
export const rewardDrawPerDevicePerHour = 10;
export const rewardCampaignCacheSeconds = 60;
export const rewardKeepDays = 30;

// 设备公钥的进程内缓存（L1）：每台最多 10 分钟。设备号与签名公钥终身绑定、不会变旧，TTL 只为多实例下别的实例删掉设备（关闭私信、不活跃清理）后，
// 本实例最迟 10 分钟内也不再认它；本实例删除时立即移除。
export const deviceKeyCacheSeconds = 10 * 60;
// 未注册设备号的负缓存（人工决策见 src/modules/device/device.service.ts）：查库没有的设备号在 Redis 记 60 秒，期间同一设备号的请求不再查库；
// 注册成功即改记「已注册」，新注册立刻在所有实例生效。
export const deviceMissingSeconds = 60;

// 诊断包（人工决策见客户端 lib/domain/diagnostic_upload.dart）：用户在开发者选项里确认后上传、在本机用开发者公钥加密过的日志包，只存密文、没有下载接口。
// 单个不超过 24MB：客户端日志包里开发者模式日志最多 20MB、错误记录两份约 1MB（lib/local/diagnostic_log.dart 的上限常量），旧日志已是 gzip、再压不小，留些余量；
// 不到一个信封头（版本、一次性公钥、随机数与 GCM 标签共 61 字节）的不收。
// 同一来源每小时 30 个（校园网 NAT 共用出口，诊断上传本来就少，一个班同时传也够；只防脚本刷满目录）。
// 保留 30 天；目录合计不超过 2GB、2000 个（清理任务每轮扫目录的工作量也因此有界），满了回 503，等到期删掉腾出地方。
export const diagnosticUploadMaxBytes = 24 * 1024 * 1024;
export const diagnosticUploadMinBytes = 61;
export const diagnosticUploadPerHour = 30;
export const diagnosticKeepDays = 30;
export const diagnosticStoreMaxBytes = 2 * 1024 * 1024 * 1024;
export const diagnosticStoreMaxFiles = 2000;
// 诊断包认领到应用账号（第 4 阶段，人工决策见客户端 lib/domain/diagnostic_upload.dart）：上传回执里的认领口令一天内有效、只能用一次；
// 认领、列出、删除按设备每小时 60 次；列表最多给 50 个（一个来源每小时最多传 30 个、30 天就删，正常远到不了）。
export const diagnosticClaimSeconds = 24 * 60 * 60;
export const diagnosticAccountRequestsPerHour = 60;
export const diagnosticAccountListLimit = 50;

// 应用账号（人工决策见 src/modules/account/account.service.ts 与客户端 lib/domain/app_account.dart）：用户名加密码，密码与恢复码在客户端用中转公钥封装后交来，
// 这里只存 scrypt 哈希。限流防撞库与刷号：注册每台设备每小时 5 个、同一来源每小时 60 个（校园网 NAT 共用出口）；
// 登录与用恢复码重设先按来源每小时 60 次，再按「用户名 + 来源」每小时 10 次、按用户名每小时 100 次（别人只用一两个出口锁不住你，分散撞库也有上限）；
// 登录着改密码、换恢复码每台设备每小时 10 次。每个实例同时最多算 passwordHashConcurrency 个哈希（每个约 32MB 内存），超出回 503 让客户端稍后再试。
// 封装后的密钥信封不超过 accountSealMaxBytes。一个账号最多同时登录在 20 把设备密钥上，再登录顶掉最久没用的那把；凭恢复码重设后只留发起的那一把。
// 账号 400 天没有任何活跃（登录、查看、账号下任一设备的签名请求，每台每小时记一次）即删除（同设备）；注销时给它的密钥记的墓碑留 accountTombstoneDays 天
// （之后这些设备也早被设备的不活跃清理删掉，再来的回 UNAUTHORIZED）。
export const accountRegisterPerDevicePerHour = 5;
export const accountRegisterPerSourcePerHour = 60;
export const accountLoginPerSourcePerHour = 60;
export const accountLoginPerUserSourcePerHour = 10;
export const accountLoginPerUserPerHour = 100;
export const accountSecretChangePerDevicePerHour = 10;
export const passwordHashConcurrency = 8;
export const accountSealMaxBytes = 1024;
export const accountDeviceLimit = 20;
export const accountIdleDays = 400;
export const accountTombstoneDays = 400;
// 扫码登录：新设备出示二维码，已登录的设备扫码核对 6 位码后批准。票据在 Redis 存 5 分钟（新设备号、核对码、批准后的账号号）；
// 新设备每小时最多出示 20 次，已登录的设备每小时最多批准 30 次。出示时就登记新设备的密钥（轮询要验签），
// 所以还没登记过的设备另按来源计数，同注册的来源档每小时 60 台（每次换新密钥的刷法挡在这里，同一台重新出示不计）。
// 票据另记出示设备自报的机型（不超过 accountJoinDeviceMaxLength 个字符）与按来源 IP 在本机离线库查出的属地（不存 IP），批准方批准前先看（每台每小时同批准 30 次）。
export const accountJoinSeconds = 5 * 60;
export const accountJoinPerDevicePerHour = 20;
export const accountJoinPerSourcePerHour = 60;
export const accountApprovePerDevicePerHour = 30;
export const accountJoinDeviceMaxLength = 64;

// 积分（人工决策见 src/modules/points/points.service.ts）：每笔获得满 12 个月过期，30 天内要过期的在余额旁提示；
// 流水满 13 个月（按 395 天）删除；剩余为 0 且过期满 30 天的获得行删除。流水每页 20 条；每台设备每小时查 600 次。
export const pointsLifetimeMonths = 12;
export const pointsExpiringDays = 30;
export const pointsEntryKeepDays = 395;
export const pointsSpentGrantKeepDays = 30;
export const pointsEntriesPage = 20;
export const pointsReadPerDevicePerHour = 600;
// 「删除游乐场与积分」（src/modules/leisure）：一台设备每小时最多删这么多次，正常人一次就够。
export const leisureDeletePerDevicePerHour = 10;
// 等级固定六档 Lv0–Lv5（门槛在灰度配置的 levels，规则见 src/modules/points/points_level.ts）。
export const pointsLevelCount = 6;

// 解锁（人工决策见 src/modules/unlock/unlock_rules.ts）：灰度配置里最多 100 项、名字 20 字、价格 1–100000 积分；每台设备每小时看 600 次、每个账号每小时买 30 次；
// 服务公开 30 天后删它的解锁记录（公开后人人可用、不退积分）；标了下架的，买过的退回积分后删记录。清理每小时一次，多实例抢锁、每轮最多 20 批、每批 1000 行。
export const unlockLimit = 100;
export const unlockTitleMax = 20;
export const unlockPriceMax = 100_000;
export const unlockReadPerDevicePerHour = 600;
export const unlockBuyPerAccountPerHour = 30;
export const unlockKeepDaysAfterPublic = 30;

// 积分时长券（人工决策见客户端 lib/toolbox/cinema/cinema_service.dart 文件头：预接好、不启用）：发布目录的 passes.json 写哪些服务要用积分换时长、
// 多少积分换几天（不放文件就都不收）；最多 passOfferLimit 种，每种最多 passDaysMax 天、passPriceMax 分，文件超过 16KB 视为放错文件。
// 看自己的券同解锁每台每小时 600 次，买每个账号每小时 30 次；到期满 passKeepDaysAfterExpire 天删记录。
export const passOfferLimit = 20;
export const passDaysMax = 366;
export const passPriceMax = 100_000;
export const passFileMaxBytes = 16 * 1024;
export const passOffersPerHour = 600;
export const passReadPerDevicePerHour = 600;
export const passBuyPerAccountPerHour = 30;
export const passKeepDaysAfterExpire = 30;

// 灰度点名（src/modules/flag_target）：一个账号最多回这么多个点名的开关（同客户端 rolloutRuleLimit），每台设备每小时最多问这么多次
// （客户端隔一小时、回到前台才问，给手动刷新与多设备留余量）。
export const flagTargetLimit = 200;
export const flagTargetReadPerDevicePerHour = 120;

// 挑战（人工决策见客户端 lib/playground/challenge/challenge_rules.dart）：一个账号同时只有一局，每小时最多开 30 局；
// 每台设备每小时 3000 个挑战请求（看列表、看局面、交答案合计）；一关错交到配置里的上限（maxErrors）就算没过。
// 一局最多 16 关；局结束 30 天后删除；最好成绩在挑战结束 400 天后删除（每个账号每周 4 行左右）。
// 配置文件不超过 256KB、每个题库文件不超过 8MB（读进内存缓存，最多 100 个文件）；到点没交的局每 5 分钟结算一批，每批 200 局。
export const challengeStartsPerAccountPerHour = 30;
export const challengeRequestsPerDevicePerHour = 3000;
export const challengeMaxLevels = 16;
export const challengeRunKeepDays = 30;
export const challengeBestKeepDays = 400;
export const challengeConfigMaxBytes = 256 * 1024;
export const challengeBankFileMaxBytes = 8 * 1024 * 1024;
export const challengeBankCacheFiles = 100;
export const challengeSweepBatch = 200;
// 预计用时的回调（见 src/modules/challenge/challenge_pace.ts）：近 challengePaceWeeks 周的过关次数够 challengePaceMinSamples 才回调，
// 倍数夹在 1/challengePaceMaxFactor 到 challengePaceMaxFactor；计数按周分开，满 challengePaceKeepWeeks 周删除；每实例缓存一小时。
export const challengePaceWeeks = 8;
export const challengePaceKeepWeeks = 12;
export const challengePaceMinSamples = 30;
export const challengePaceMaxFactor = 2;
export const challengePaceCacheMs = 3600_000;

// 设备 400 天没有任何请求即删除，连同其好友关系与待取消息。
export const deviceIdleDays = 400;
// 最后活跃时间每设备最多每小时写一次库。
export const seenWriteSeconds = 60 * 60;

// 清理任务每批删除 1000 行，避免长事务与大锁。
export const cleanupBatch = 1000;
// 不活跃设备按每 10 台一个事务删除：每台连带最多 1000 行好友关系（双向）与 1000 条待取消息，单个事务约 2 万行封顶。
export const deviceRemovalChunk = 10;

// 运维（人工决策见 src/common/error_monitor.ts）：就绪探测 /v1/health/ready 对 MySQL 与 Redis 各等 readinessTimeoutMs；
// 错误计数按签名每分钟一轮，error 级日志一分钟 errorAlertPerMinute 次、主动卸载负载的 503 一分钟 shedAlertPerMinute 次即告警，
// 同一签名 errorAlertFoldMinutes 分钟内只写第一条、其余合成一条汇总；最多跟踪 errorMonitorMaxSignatures 个签名（多的并进 other）；每 errorStatsMinutes 分钟写一行汇总。
export const readinessTimeoutMs = 1000;
// [人工决策-2026-11-19 18:17:27] errorAlertPerMinute 维持 1（用户让按业界最佳实践定）：Alpha 期间流量小、正常运行不该有 error 级日志，出现一条就是要看的新问题
// （同 Sentry 的「新问题」告警）；刷屏由按签名 errorAlertFoldMinutes 折叠兜住。用户量上来、出现可接受的背景错误后，再改成按错误率与时间窗告警。
export const errorAlertPerMinute = 1;
export const shedAlertPerMinute = 20;
export const errorAlertFoldMinutes = 60;
export const errorMonitorMaxSignatures = 50;
export const errorStatsMinutes = 60;
