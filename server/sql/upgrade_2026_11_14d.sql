-- 2026-11-14 第 5 阶段：节日红包的金额档（规则见 src/modules/reward/reward_odds.ts 的人工决策）。由人工在已有的库上执行（服务启动不做 DDL）。
-- 新列带默认值，旧版服务照常能导入与发奖，所以可以先执行本文件再部署新版服务。
-- 可重复执行（11-17 把一条 ALTER 拆成三步、每步先查 information_schema：加列、先建新索引再删旧索引，中途失败重跑接着做；线上 11-14 执行的原版结果相同）。

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reward_prize' AND COLUMN_NAME = 'tier');
SET @ddl := IF(@have = 0,
  'ALTER TABLE reward_prize ADD COLUMN tier TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''金额档：0 普通，数越大金额越高（抽中后大额档按积分等级加权挑）'' AFTER campaign_id',
  'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reward_prize' AND INDEX_NAME = 'idx_campaign_tier_draw');
SET @ddl := IF(@have = 0, 'ALTER TABLE reward_prize ADD KEY idx_campaign_tier_draw (campaign_id, tier, draw_id)', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reward_prize' AND INDEX_NAME = 'idx_campaign_draw');
SET @ddl := IF(@have > 0, 'ALTER TABLE reward_prize DROP INDEX idx_campaign_draw', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;
