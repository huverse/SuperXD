-- 2026-11-28 红包每档的库存计数（Codex 审查 F07）：抽中时原来在活动锁里按档汇总这次活动的全部奖品（COUNT 整个活动的奖品行），
-- 一次领取的工作量随活动库存增长、又被活动锁串行化。改成每个活动每档一行计数：导入奖品时加 stock、发出一份时加 given，都与奖品行同一事务；
-- 领取只读这几行、再取一件奖品。由人工在已有的库上执行（服务启动不做 DDL），先于新版服务；旧版服务不读这张表。
-- 可重复执行：建表 IF NOT EXISTS；回填按奖品表重算、覆盖已有的计数（部署前后各跑一次都是对的数）。
CREATE TABLE IF NOT EXISTS reward_tier_stock (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  campaign_id BIGINT UNSIGNED NOT NULL,
  tier TINYINT UNSIGNED NOT NULL COMMENT '金额档，同 reward_prize.tier',
  stock INT NOT NULL COMMENT '这一档导入的奖品份数',
  given INT NOT NULL COMMENT '这一档已经发出的份数',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_reward_tier_stock (campaign_id, tier)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

INSERT INTO reward_tier_stock (campaign_id, tier, stock, given, create_time, update_time)
SELECT campaign_id, tier, COUNT(*), COUNT(draw_id), NOW(3), NOW(3) FROM reward_prize GROUP BY campaign_id, tier
ON DUPLICATE KEY UPDATE stock = VALUES(stock), given = VALUES(given), update_time = VALUES(update_time);
