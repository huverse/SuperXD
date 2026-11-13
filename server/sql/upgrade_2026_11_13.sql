-- 2026-11-13 应用账号：建 app_account、account_identity、account_device 三张表。由人工在已有的库上执行一次（服务启动不做 DDL），先执行本文件再部署新版服务。

-- 应用账号（人工决策见 src/modules/account/account_provider.ts）：对外只有随机账号号；400 天没有登录或查看即连同下面两张表的行删除。
CREATE TABLE IF NOT EXISTS app_account (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL COMMENT '随机账号号 base64url，客户端拿它做灰度分桶',
  last_seen_time DATETIME(3) NOT NULL COMMENT '最后登录或查看',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_account_id (account_id),
  KEY idx_last_seen (last_seen_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 账号的登录方式：主体（教务是来源加学号）只存带服务器密钥的 HMAC，学号不落库。一种登录方式的一个主体只属于一个账号。
CREATE TABLE IF NOT EXISTS account_identity (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  provider VARCHAR(16) NOT NULL COMMENT '登录方式，现在只有 kingo',
  subject_hash VARCHAR(64) NOT NULL COMMENT 'HMAC-SHA256 base64url',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_provider_subject (provider, subject_hash),
  KEY idx_account (account_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 账号登录在哪些设备密钥上：一把密钥只属于一个账号，每个账号最多 20 把；设备删除时连带删除。
CREATE TABLE IF NOT EXISTS account_device (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  device_id VARCHAR(32) NOT NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_device (device_id),
  KEY idx_account (account_id, update_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
