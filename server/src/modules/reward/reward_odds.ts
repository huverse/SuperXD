// [人工决策-2026-10-23 23:25:34] 节日抽奖的概率模型（用户要求有平权与按活跃度加权两种，选「打开即抽、全天均匀放量」，
// 未选「定时统一开奖」；没抽中的人不打扰，见客户端 lib/application/festivals.dart）。奖品（支付宝口令、二维码）是秘密，
// 只放服务器、只在服务器抽，客户端只展示（同大厂抽奖：库存、每人一次、概率都在服务端）。每次活动选一种模式：
// - 平权 uniform：人人权重 1，抽中概率 = baseChance。
// - 按活跃度加权 weighted：权重 = 1 + (maxWeight − 1) × min(活跃天数, 20) / 20，活跃天数是客户端报的近 30 天里打开过应用的天数；
//   20 天及以上到上限 maxWeight（如 3：最活跃的人是新用户的 3 倍），有上限是为了老用户多些机会、但不垄断。抽中概率 = min(1, baseChance × 权重)。
//   活跃天数由客户端本机记、可以被改过的客户端虚报，奖品价值小，接受；服务端不另记谁每天打开过（那等于新增追踪）。
// - 均匀放量：奖品按活动时长均分到每个小时，第 k 个小时里最多累计放出 ceil(总数 × k / 小时数) 份，半夜与晚上打开的人机会一样、
//   不会在开始时被抢光；抽中了但这一小时的额度已用完的算没抽中，没放完的额度留给后面的小时。最后一个小时放出全部剩余。
// 抽签按参与号幂等：同一活动同一参与号只抽一次，重复请求返回同一个结果（含没抽中），防止反复重抽。
export const rewardModes = ['uniform', 'weighted'] as const;
export type RewardMode = (typeof rewardModes)[number];

// 活跃天数到这么多就到加权上限。
export const rewardActiveSaturation = 20;
// 客户端报的活跃天数只认近 30 天。
export const rewardActiveWindow = 30;

export const rewardWeight = (mode: RewardMode, activeDays: number, maxWeight: number): number => {
  if (mode === 'uniform') return 1;
  const days = Math.min(Math.max(activeDays, 0), rewardActiveSaturation);
  return 1 + ((maxWeight - 1) * days) / rewardActiveSaturation;
};

export const rewardChance = (baseChance: number, weight: number): number => Math.min(1, baseChance * weight);

// 到 now 为止最多放出的份数：活动按小时切段，所在的第 k 段（从 1 数）结束前累计 ceil(stock × k / 段数)。
export const rewardReleased = (stock: number, startsAt: Date, endsAt: Date, now: Date): number => {
  const hour = 3600_000;
  const slots = Math.max(1, Math.ceil((endsAt.getTime() - startsAt.getTime()) / hour));
  const slot = Math.min(slots, Math.floor((now.getTime() - startsAt.getTime()) / hour) + 1);
  return Math.ceil((stock * slot) / slots);
};
