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
// 清单文件超过 64KB 视为放错文件，拒绝读取。
export const appReleasePerHour = 600;
export const appFilePerHour = 300;
export const appDownloadsPerInstance = 32;
export const appReleaseFileMaxBytes = 64 * 1024;

// 开发者的话：维护者写的信由流水线放进发布目录（developer_notes.json），客户端启动与回到前台时看一眼（间隔不到一小时不联网），
// 同一 IP 每小时 600 次（与查清单同档）。只下发最近 30 封，标题不超过 40 字、正文不超过 4000 字（与客户端 lib/domain/developer_note.dart 一致），
// 文件超过 512KB 视为放错文件，拒绝读取。
export const developerNotesPerHour = 600;
export const developerNoteLimit = 30;
export const developerNoteTitleMax = 40;
export const developerNoteBodyMax = 4000;
export const developerNotesFileMaxBytes = 512 * 1024;

// 节日抽奖（概率模型见 src/modules/reward/reward_odds.ts）：同一来源每小时 3000 次（校园网 NAT 共用出口，同代签取件的宽松档；
// 每个参与号只抽一次、重复请求返回同一结果，限流只防脚本刷库）；活动行在进程内缓存 60 秒（建活动、改时间最迟一分钟生效）；
// 活动结束 30 天后连同奖品与抽签记录删除。
export const rewardDrawPerHour = 3000;
export const rewardCampaignCacheSeconds = 60;
export const rewardKeepDays = 30;

// 设备 400 天没有任何请求即删除，连同其好友关系与待取消息。
export const deviceIdleDays = 400;
// 最后活跃时间每设备最多每小时写一次库。
export const seenWriteSeconds = 60 * 60;

// 清理任务每批删除 1000 行，避免长事务与大锁。
export const cleanupBatch = 1000;
// 不活跃设备按每 10 台一个事务删除：每台连带最多 1000 行好友关系（双向）与 1000 条待取消息，单个事务约 2 万行封顶。
export const deviceRemovalChunk = 10;
