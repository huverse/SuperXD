// 积分等级（[人工决策-2026-11-14 20:20:18] 用户选「积分加等级」与「六档 Lv0–Lv5」）：积分照旧能花、满 12 个月过期；
// 等级按近 12 个月获得的积分总数算（花了不减、过期才降，解锁下架退回的不算），灰度、隐藏服务与红包的加权都看等级，兑换不会让人掉资格（同京豆与京享值两本账）。
// 门槛写在灰度配置 rollout.json 的 levels（六个数，从 0 起严格递增，维护者本机签好后用 tool/rollout_publish.sh 上传，改了不用发版）；还没放配置时人人 Lv0。
export type PointsLevel = { level: number; next: number | null };

export const levelOf = (earned: number, thresholds: number[]): PointsLevel => {
  let level = 0;
  while (level + 1 < thresholds.length && earned >= thresholds[level + 1]) level++;
  return { level, next: level + 1 < thresholds.length ? thresholds[level + 1] : null };
};
