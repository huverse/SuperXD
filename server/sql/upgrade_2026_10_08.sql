-- 2026-10-08 代签码轮换即作废：chaoxing_pack 加作废口令哈希。由人工在已有的库上执行（服务启动不做 DDL），部署时经 scripts/migrate_db.sh 执行并登记台账。
-- 先执行本文件再部署新版服务；老版本服务插入时不带这一列，按默认空串存，空串对不上任何口令，不影响取件。
-- 可重复执行（11-17 改成先查 information_schema、列已在就跳过；线上 10-08 执行的原版结果相同）。
SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chaoxing_pack' AND COLUMN_NAME = 'revoke_hash');
SET @ddl := IF(@have = 0,
  'ALTER TABLE chaoxing_pack ADD COLUMN revoke_hash VARCHAR(64) NOT NULL DEFAULT '''' COMMENT ''作废口令的 sha256 十六进制；口令只在投递响应里给出示方一次'' AFTER expire_time',
  'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;
