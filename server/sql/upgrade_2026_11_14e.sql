-- 2026-11-14 第 5 阶段：解锁（隐藏服务与新游戏抢先玩，规则见 src/modules/unlock/unlock_rules.ts）。由人工在已有的库上执行一次（服务启动不做 DDL），先执行本文件再部署新版服务；建表可重复执行。

-- 账号记过的解锁（规则见 src/modules/unlock/unlock_rules.ts）：花积分买的（buy）与按等级加权抽签抽中的（drawn），一个账号一项一行；
-- 随账号删除；服务公开 30 天后、或下架退回积分后由每小时一次的清理任务删除。
CREATE TABLE IF NOT EXISTS account_unlock (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  unlock_id VARCHAR(64) NOT NULL COMMENT '灰度配置 unlocks 里的编号，如 game.sudoku',
  source VARCHAR(8) NOT NULL COMMENT 'buy 花积分买的，drawn 抽签抽中的',
  price INT UNSIGNED NOT NULL COMMENT '付的积分，抽中的为 0（下架时按它退回）',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_account_unlock (account_id, unlock_id),
  KEY idx_unlock (unlock_id, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
