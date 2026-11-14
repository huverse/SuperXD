// 中转服务的全部上限与保留期集中在这里；改动须同步 README 的“上限与保留”，以及客户端索引（私信见 lib/social/CLAUDE.md，代签见 lib/toolbox/CLAUDE.md 与根 CLAUDE.md 的数据保留）。

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
export const developerNotesFileMaxBytes = 1024 * 1024;

// 灰度配置（人工决策见客户端 lib/domain/rollout.dart）：流水线由仓库 rollout/rollout.json 签好放进发布目录（tool/rollout_config.dart），
// 客户端同意协议与政策后、回到前台时看一眼（间隔不到一小时不联网），同一 IP 每小时 600 次（与开发者的话同档）。最多 200 个开关、每个 20 档，
// 明文加签名载荷两份也远不到 64KB，文件超过 64KB 视为放错文件，拒绝读取（与客户端 lib/device/relay_rollout_feed.dart 的响应上限一致）。
export const rolloutConfigPerHour = 600;
export const rolloutFlagLimit = 200;
export const rolloutStageLimit = 20;
export const rolloutFileMaxBytes = 64 * 1024;

// 节日抽奖（概率模型与要求设备签名的人工决策见 src/modules/reward/reward_odds.ts）：同一来源每小时 3000 次（校园网 NAT 共用出口，同代签取件的宽松档），
// 每台设备每小时 10 次（一台设备一次活动只抽一次、重复请求返回同一结果，正常客户端只在没连上时补抽；按设备计数让刷请求的设备先被自己的额度挡住）；
// 刷号的成本是注册限流 registerPerHour。活动行在进程内缓存 60 秒（建活动、改时间最迟一分钟生效）；活动结束 30 天后连同奖品与抽签记录删除。
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

// 应用账号（人工决策见 src/modules/account/account_provider.ts 与客户端 lib/domain/app_account.dart）：
// 登录核对要中转代登录一次学校教务，限流防两件事——被拿来试同学的密码（按学号每天最多 10 次尝试，含验证码重试），
// 以及学校看到我们的 IP 大量登录（全局每小时 600 次，所有实例共用一个计数）。同一来源每小时 300 次（校园网 NAT 共用出口），每台设备每小时 10 次。
// 每个实例同时最多 4 个代登录在跑（每个要连发七八个教务请求），超出回 503 让客户端稍后再试。
// 教务每个请求 12 秒超时、整次核对最多 40 秒（客户端等 45 秒）；教务响应超过 1MB 当格式不对。
// 需要验证码时教务会话在 Redis 存 5 分钟（只有 cookie 与页面会话号，不存口令摘要，答题时客户端重新加密交来）。
// 封装后的口令摘要不超过 1KB（明文 JSON 两百来字节加 61 字节信封头）。
// 一个账号最多同时登录在 20 把设备密钥上，再登录顶掉最久没用的那把；账号 400 天没有登录或查看即删除（同设备）。
export const accountSignInPerDevicePerHour = 10;
export const accountSignInPerSourcePerHour = 300;
export const accountSignInPerHour = 600;
export const accountSignInPerSubjectPerDay = 10;
export const kingoConcurrentPerInstance = 4;
export const kingoRequestTimeoutMs = 12_000;
export const kingoSignInDeadlineMs = 40_000;
export const kingoResponseMaxBytes = 1024 * 1024;
export const kingoChallengeSeconds = 5 * 60;
export const accountSealMaxBytes = 1024;
export const accountDeviceLimit = 20;
export const accountIdleDays = 400;

// 积分（人工决策见 src/modules/points/points.service.ts）：每笔获得满 12 个月过期，30 天内要过期的在余额旁提示；
// 流水满 13 个月（按 395 天）删除；剩余为 0 且过期满 30 天的获得行删除。流水每页 20 条；每台设备每小时查 600 次。
export const pointsLifetimeMonths = 12;
export const pointsExpiringDays = 30;
export const pointsEntryKeepDays = 395;
export const pointsSpentGrantKeepDays = 30;
export const pointsEntriesPage = 20;
export const pointsReadPerDevicePerHour = 600;

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

// 设备 400 天没有任何请求即删除，连同其好友关系与待取消息。
export const deviceIdleDays = 400;
// 最后活跃时间每设备最多每小时写一次库。
export const seenWriteSeconds = 60 * 60;

// 清理任务每批删除 1000 行，避免长事务与大锁。
export const cleanupBatch = 1000;
// 不活跃设备按每 10 台一个事务删除：每台连带最多 1000 行好友关系（双向）与 1000 条待取消息，单个事务约 2 万行封顶。
export const deviceRemovalChunk = 10;
