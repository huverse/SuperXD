-- 2026-11-16 红包的资格与发放由每个活动的参数决定（人工决策见 src/modules/reward/reward_odds.ts 的 11-16 那条）：reward_campaign 加 distribution、audience、
-- min_account_days、min_level 四列（默认值即原来的行为：抽签、人人可参加、账号满 7 天、不看等级），新建名单表 reward_audience。
-- 由人工在已有的库上执行（服务启动不做 DDL）；加列是 INSTANT、不重建表，旧版服务不读新列，可以先执行再部署。可重复执行。
SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reward_campaign' AND COLUMN_NAME = 'distribution');
SET @ddl := IF(@have = 0, 'ALTER TABLE reward_campaign ADD COLUMN distribution VARCHAR(8) NOT NULL DEFAULT ''lottery'' COMMENT ''lottery 抽签，all 有资格就发（发完为止）'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reward_campaign' AND COLUMN_NAME = 'audience');
SET @ddl := IF(@have = 0, 'ALTER TABLE reward_campaign ADD COLUMN audience VARCHAR(8) NOT NULL DEFAULT ''everyone'' COMMENT ''everyone 人人可参加，list 只有 reward_audience 名单里的应用账号'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reward_campaign' AND COLUMN_NAME = 'min_account_days');
SET @ddl := IF(@have = 0, 'ALTER TABLE reward_campaign ADD COLUMN min_account_days SMALLINT UNSIGNED NOT NULL DEFAULT 7 COMMENT ''应用账号建立满几天才能参加'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reward_campaign' AND COLUMN_NAME = 'min_level');
SET @ddl := IF(@have = 0, 'ALTER TABLE reward_campaign ADD COLUMN min_level TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''最低积分等级 0–5'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;
-- 名单活动的名单：一个应用账号一行，由 reward_admin audience 按用户名导入；随活动删除（活动结束 30 天后）、随账号删除。
CREATE TABLE IF NOT EXISTS reward_audience (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  campaign_id BIGINT UNSIGNED NOT NULL,
  account_id VARCHAR(32) NOT NULL COMMENT '应用账号号',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_campaign_account (campaign_id, account_id),
  KEY idx_account (account_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
