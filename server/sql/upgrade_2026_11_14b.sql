-- 2026-11-14 第 4 阶段：诊断包认领到应用账号。由人工在已有的库上执行一次（服务启动不做 DDL），先执行本文件再部署新版服务。

-- 认领到应用账号的诊断包（人工决策见客户端 lib/domain/diagnostic_upload.dart）：只记认领过的，随包到期（30 天）、用户删除或注销账号删除。
CREATE TABLE IF NOT EXISTS diagnostic_upload (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  diagnostic_id CHAR(8) NOT NULL COMMENT '诊断编号，同目录里的文件名',
  account_id VARCHAR(32) NOT NULL,
  bytes INT UNSIGNED NOT NULL COMMENT '密文大小',
  create_time DATETIME(3) NOT NULL COMMENT '认领时刻（上传后一天内）',
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_diagnostic (diagnostic_id),
  KEY idx_account (account_id, id),
  KEY idx_create (create_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
