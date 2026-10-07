// 中转服务的全部上限与保留期集中在这里；改动须同步 README 的“上限与保留”和客户端 lib/social/CLAUDE.md。

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
// 穷举不可行，限流只防脚本刷库撑爆存储（包本身 2KB、10 分钟后清理）。
export const chaoxingPackMaxBytes = 2 * 1024;
export const chaoxingPackTtlSeconds = 10 * 60;
export const chaoxingPackPerHour = 1000;
export const chaoxingPackPickupPerHour = 3000;

// 设备 400 天没有任何请求即删除，连同其好友关系与待取消息。
export const deviceIdleDays = 400;
// 最后活跃时间每设备最多每小时写一次库。
export const seenWriteSeconds = 60 * 60;

// 清理任务每批删除 1000 行，避免长事务与大锁。
export const cleanupBatch = 1000;
