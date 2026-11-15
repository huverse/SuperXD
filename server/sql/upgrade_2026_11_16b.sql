-- 2026-11-16 已注销账号的设备密钥记墓碑（人工决策见 src/modules/account/account.service.ts 的 remove）：注销账号时给它的每把设备密钥记一行，
-- 这些密钥再来回 ACCOUNT_DELETED，客户端据此清掉本机那个账号的私信；被顶掉、恢复码重设踢下线的照旧回 ACCOUNT_NOT_FOUND。
-- 只有设备号与时刻，保留 400 天，由账号的清理任务每小时分批删。由人工在已有的库上执行（服务启动不做 DDL）；只建表，旧版服务不碰它，
-- 可以先执行再部署（新版服务注销账号时要写这张表，所以必须在部署新版之前执行）。可重复执行。
CREATE TABLE IF NOT EXISTS account_tombstone (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  device_id VARCHAR(32) NOT NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_device (device_id),
  KEY idx_create (create_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
