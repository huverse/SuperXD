-- 2026-11-16 灰度点名（人工决策见客户端 lib/domain/rollout.dart 的 11-16 那条）：开发者用管理命令 flag_admin 把某个开关单独开给某个应用账号，
-- 名单只在服务器、不进公开的灰度配置；手机登录着应用账号时签名来问 GET /v1/flags/mine。随账号删除，到期的每天清。
-- 由人工在已有的库上执行（服务启动不做 DDL）；只建表，旧版服务不碰它，可以先执行再部署。可重复执行。
CREATE TABLE IF NOT EXISTS rollout_target (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  flag_id VARCHAR(64) NOT NULL COMMENT '开关编号，同灰度配置里的 id',
  account_id VARCHAR(32) NOT NULL COMMENT '应用账号号',
  expires_at DATETIME(3) NULL COMMENT '点到什么时刻，为空是一直开到撤销',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_flag_account (flag_id, account_id),
  KEY idx_account_expires (account_id, expires_at),
  KEY idx_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
