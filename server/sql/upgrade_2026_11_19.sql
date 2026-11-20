-- 2026-11-19 电影院的积分时长券（人工决策见客户端 lib/toolbox/cinema/cinema_service.dart 文件头：预接好、不启用）：新表 account_pass，
-- 一个账号一种券一行，记到期时刻（UTC）与累计付的积分；续买把到期时刻往后叠加。随账号删除，到期满 30 天删除。
-- 由人工在已有的库上执行（服务启动不做 DDL）；只新建表，旧版服务不读它。可重复执行。
CREATE TABLE IF NOT EXISTS account_pass (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  pass_id VARCHAR(64) NOT NULL COMMENT '发布目录 passes.json 里的编号，如 toolbox.cinema',
  expire_time DATETIME(3) NOT NULL COMMENT '到期时刻（UTC）',
  paid INT UNSIGNED NOT NULL COMMENT '累计付的积分',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_account_pass (account_id, pass_id),
  KEY idx_expire (expire_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
