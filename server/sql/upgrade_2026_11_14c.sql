-- 2026-11-14 第 4 阶段：私信跟着应用账号。由人工在已有的库上执行（服务启动不做 DDL），先执行本文件再部署新版服务。
-- 可重复执行（11-17 把加列改成先查 information_schema、列已在就跳过；线上 11-14 执行的原版结果相同）。

-- 好友换了设备的提示（人工决策见客户端 lib/social/social_service.dart 文件头）：加在末尾的可空列，MySQL 8.4 按 INSTANT 加，不重建表。
SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'friendship' AND COLUMN_NAME = 'moved_from');
SET @ddl := IF(@have = 0,
  'ALTER TABLE friendship ADD COLUMN moved_from VARCHAR(32) NULL COMMENT ''对方的私信换到了 peer 这台新设备，owner 还认得的旧设备号；owner 确认后清空''',
  'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

-- 应用账号的私信设备：一个账号同一时刻一台，接管时改指新设备；删设备与注销账号时删。行数以账号数为界。
CREATE TABLE IF NOT EXISTS account_social (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  device_id VARCHAR(32) NOT NULL COMMENT '私信设备号',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_account (account_id),
  UNIQUE KEY uk_device (device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
