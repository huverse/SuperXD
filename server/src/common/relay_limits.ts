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

// 设备 400 天没有任何请求即删除，连同其好友关系与待取消息。
export const deviceIdleDays = 400;
// 最后活跃时间每设备最多每小时写一次库。
export const seenWriteSeconds = 60 * 60;

// 清理任务每批删除 1000 行，避免长事务与大锁。
export const cleanupBatch = 1000;
