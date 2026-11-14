-- 2026-11-14 积分与挑战：建 points_grant、points_entry、challenge_run、challenge_best 四张表。由人工在已有的库上执行一次（服务启动不做 DDL），先执行本文件再部署新版服务。

-- 积分每笔获得一行（人工决策见 src/modules/points/points.service.ts）：满 12 个月过期；余额 = 没过期的 remaining 之和；剩余为 0 且过期满 30 天删除。
CREATE TABLE IF NOT EXISTS points_grant (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  amount INT UNSIGNED NOT NULL,
  remaining INT UNSIGNED NOT NULL,
  source VARCHAR(16) NOT NULL COMMENT '来源，现在只有 challenge',
  source_key VARCHAR(64) NOT NULL COMMENT '幂等键：同一来源同一个键只记一次（挑战是这一局的编号）',
  expire_time DATETIME(3) NOT NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_source (source, source_key),
  KEY idx_account_expire (account_id, expire_time),
  KEY idx_expire (expire_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 积分流水：只增，满 13 个月删除。
CREATE TABLE IF NOT EXISTS points_entry (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  kind VARCHAR(8) NOT NULL COMMENT 'earn 获得、expire 过期、spend 花费、refund 退回',
  amount INT NOT NULL COMMENT '正数加、负数减',
  note VARCHAR(64) NOT NULL COMMENT '给用户看的说明',
  ref VARCHAR(64) NOT NULL COMMENT '关联：挑战局编号、过期的那笔获得',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  KEY idx_account (account_id, id),
  KEY idx_time (create_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 挑战的一局（人工决策见客户端 lib/playground/challenge/challenge_rules.dart）：计划与进度是 JSON 文本；active 进行中为 1、结算后为空，
-- (account_id, active) 唯一，一个账号同时只有一局进行中。结束满 30 天删除。
CREATE TABLE IF NOT EXISTS challenge_run (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  run_id VARCHAR(32) NOT NULL,
  account_id VARCHAR(32) NOT NULL,
  challenge_id VARCHAR(64) NOT NULL,
  active TINYINT NULL,
  deadline DATETIME(3) NOT NULL,
  plan MEDIUMTEXT NOT NULL COMMENT '关卡图、题面、钥匙与计分参数快照',
  progress TEXT NOT NULL COMMENT '每关的状态、解锁与过关时刻、错交次数',
  ending VARCHAR(8) NULL COMMENT 'cleared、stuck、timeout、ended',
  points INT UNSIGNED NULL,
  awarded INT UNSIGNED NULL,
  end_time DATETIME(3) NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_run (run_id),
  UNIQUE KEY uk_account_active (account_id, active),
  KEY idx_active_deadline (active, deadline),
  KEY idx_end_time (end_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 每个账号每个挑战的最好成绩：重复挑战只补超过它的差额；挑战结束满 400 天删除。
CREATE TABLE IF NOT EXISTS challenge_best (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  challenge_id VARCHAR(64) NOT NULL,
  points INT UNSIGNED NOT NULL,
  run_id VARCHAR(32) NOT NULL,
  ends_at DATETIME(3) NOT NULL COMMENT '挑战的开放结束时刻',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_account_challenge (account_id, challenge_id),
  KEY idx_ends (ends_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
