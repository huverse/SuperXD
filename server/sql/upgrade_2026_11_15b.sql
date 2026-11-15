-- 2026-11-15 应用账号改为设备核对（学校封了中转的 IP，人工决策见 src/modules/account/account.service.ts 的 deviceSignIn）：找回申请表。
-- 由人工在已有的库上执行一次（服务启动不做 DDL），先执行本文件再部署新版服务；可重复执行。

-- 账号还有设备登着时新设备提交的找回申请：等 3 天，账号的设备可以拒绝或批准；满 30 天删除（account_retention.task.ts）。
CREATE TABLE IF NOT EXISTS account_recovery (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  device_id VARCHAR(32) NOT NULL COMMENT '提交申请的新设备号',
  state VARCHAR(8) NOT NULL COMMENT 'pending、granted、denied、conflict',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  KEY idx_account (account_id, state),
  KEY idx_device (device_id, id),
  KEY idx_create (create_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
