import { inviteTtlSeconds, nonceTtlSeconds, seenWriteSeconds } from 'src/common/relay_limits';

// Redis key 注册表：所有 key 在此构造，service 不得硬编码 key 字符串。全局前缀由 REDIS_KEY_PREFIX 配置（ioredis keyPrefix）。
// 这里全部是运行态或可丢的短期状态，权威数据只在 MySQL。丢了的后果：邀请失效需重新出示、限流窗口归零、
// 进行中的清理任务锁释放（下一轮重抢），均可自愈；随机数丢了则 5 分钟校时窗口内截获的请求可被重放一次。
// 部署用 maxmemory-policy volatile-ttl，内存满时先淘汰剩余寿命最短的 key，随机数与邀请首当其冲，所以 Redis 内存要留足余量。
export const RedisKeyTTL = {
  nonce: nonceTtlSeconds,
  invite: inviteTtlSeconds,
  seen: seenWriteSeconds,
} as const;

export const RedisKeys = {
  // 请求随机数去重，单值，按设备分散。
  nonce: (deviceId: string, nonce: string) => `nonce:${deviceId}:${nonce}`,
  // 邀请：Hash {ownerDeviceId, publicKey}，字段固定 2 个。
  invite: (inviteId: string) => `invite:${inviteId}`,
  // 设备当前有效邀请号，单值；新建邀请时据此作废旧的。
  inviteOwner: (deviceId: string) => `invite_owner:${deviceId}`,
  // 固定窗口限流计数，单值，TTL 等于窗口长度。
  rate: (scope: string, subject: string, window: number) => `rate:${scope}:${subject}:${window}`,
  // 最后活跃写库节流标记，单值。
  seen: (deviceId: string) => `seen:${deviceId}`,
  // 分布式锁，单值，持有者令牌。
  lock: (name: string) => `lock:${name}`,
} as const;

// 发布订阅频道：ioredis 的 keyPrefix 不作用于频道名，这里手动加同一前缀隔离环境。
export const RedisChannels = {
  // 信箱有新消息，载荷是收件设备号；各实例只唤醒自己持有的长轮询。
  mailNotify: (keyPrefix: string) => `${keyPrefix}mail_notify`,
} as const;
