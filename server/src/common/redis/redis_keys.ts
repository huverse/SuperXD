import { deviceMissingSeconds, diagnosticClaimSeconds, inviteTtlSeconds, kingoChallengeSeconds, nonceTtlSeconds, seenWriteSeconds } from 'src/common/relay_limits';

// Redis key 注册表：所有 key 在此构造，service 不得硬编码 key 字符串。全局前缀由 REDIS_KEY_PREFIX 配置（ioredis keyPrefix）。
// 这里全部是运行态或可丢的短期状态，权威数据只在 MySQL。丢了的后果：邀请失效需重新出示、限流窗口归零、
// 进行中的清理任务锁释放（下一轮重抢），均可自愈；随机数丢了则 5 分钟校时窗口内截获的请求可被重放一次。
// 部署用 maxmemory-policy volatile-ttl，内存满时先淘汰剩余寿命最短的 key，随机数与邀请首当其冲，所以 Redis 内存要留足余量。
export const RedisKeyTTL = {
  nonce: nonceTtlSeconds,
  invite: inviteTtlSeconds,
  seen: seenWriteSeconds,
  deviceMissing: deviceMissingSeconds,
  // 清理任务每 10 分钟按目录重写一次并续期；任务停了一天才过期（之后上限从零重计，靠清理任务恢复后重建）。
  diagnosticUsage: 24 * 60 * 60,
  kingoChallenge: kingoChallengeSeconds,
  diagnosticClaim: diagnosticClaimSeconds,
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
  // 设备号负缓存，单值：missing 表示查库没有这台设备，registered 表示刚注册（挡住与注册交错的查库把它写回 missing）。
  deviceMissing: (deviceId: string) => `device_missing:${deviceId}`,
  // 分布式锁，单值，持有者令牌。
  lock: (name: string) => `lock:${name}`,
  // 诊断包目录的已用量：Hash {bytes, files}，字段固定 2 个。上传时原子预占、写盘失败退回，清理任务每轮按目录实际重写（丢了也由它重建，在那之前上限偏松）。
  diagnosticUsage: () => 'diagnostic_usage',
  // 应用账号登录要验证码时的教务会话：单值 JSON {deviceId, jar, pageSession}，cookie 只有教务给的几项，几百字节；5 分钟过期，答题时取出即删。
  // 丢了只是这次要重新登录。
  kingoChallenge: (challengeId: string) => `kingo_challenge:${challengeId}`,
  // 诊断包的认领口令：单值，口令的 sha256 十六进制；一天过期，认领时核对后删掉。丢了只是这个包认领不了、照旧匿名。
  diagnosticClaim: (diagnosticId: string) => `diagnostic_claim:${diagnosticId}`,
} as const;

// 发布订阅频道：ioredis 的 keyPrefix 不作用于频道名，这里手动加同一前缀隔离环境。
export const RedisChannels = {
  // 信箱有新消息，载荷是收件设备号；各实例只唤醒自己持有的长轮询。
  mailNotify: (keyPrefix: string) => `${keyPrefix}mail_notify`,
} as const;
