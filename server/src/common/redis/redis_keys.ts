import { inviteTtlSeconds, nonceTtlSeconds, seenWriteSeconds } from 'src/common/relay_limits';

// Redis key 注册表：所有 key 在此构造，service 不得硬编码 key 字符串。全局前缀由 REDIS_KEY_PREFIX 配置（ioredis keyPrefix）。
// 这里全部是运行态或可丢的短期状态：丢了的后果是邀请失效需重新出示、限流窗口归零，均可自愈；权威数据只在 MySQL。
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
