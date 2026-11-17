-- 2026-11-17 表结构升级台账（人工决策见 scripts/migrate_db.sh 文件头）：scripts/migrate_db.sh 按文件名顺序执行 sql 下还没登记的 upgrade_*.sql，
-- 每执行完一个在这里登记一行（文件名、时刻、文件内容的 sha256），部署只跑台账里没有的。台账脚本发现台账表还没建时先执行本文件。
-- 由人工执行（服务启动不做 DDL）；只建表，服务不读不写它。可重复执行。
-- 保留：一个升级文件一行（一年几十行），永久保留、不清理；进备份（恢复后台账回到备份时，再跑台账脚本就把之后的升级补上）。
CREATE TABLE IF NOT EXISTS schema_migration (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  file_name VARCHAR(64) NOT NULL COMMENT 'sql 下的升级文件名，如 upgrade_2026_11_17.sql',
  checksum CHAR(64) NOT NULL COMMENT '登记时文件内容的 sha256 十六进制；之后文件被改过，台账脚本停下等人核对',
  mode VARCHAR(8) NOT NULL COMMENT 'applied 由台账脚本执行，baseline 接入台账前已手工执行、只登记',
  create_time DATETIME(3) NOT NULL COMMENT '执行或登记的时刻',
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_file (file_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
