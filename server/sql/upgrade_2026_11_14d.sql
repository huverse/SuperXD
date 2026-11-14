-- 2026-11-14 第 5 阶段：节日红包的金额档（规则见 src/modules/reward/reward_odds.ts 的人工决策）。由人工在已有的库上执行一次（服务启动不做 DDL）。
-- 新列带默认值，旧版服务照常能导入与发奖，所以可以先执行本文件再部署新版服务。加列与换索引不能重复执行：中途失败时先 SHOW CREATE TABLE reward_prize 看做到哪一步，再只执行剩下的。

ALTER TABLE reward_prize
  ADD COLUMN tier TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '金额档：0 普通，数越大金额越高（抽中后大额档按积分等级加权挑）' AFTER campaign_id,
  DROP INDEX idx_campaign_draw,
  ADD KEY idx_campaign_tier_draw (campaign_id, tier, draw_id);
