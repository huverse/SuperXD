-- 2026-11-20 片名目录的单字搜索走索引（人工决策见 src/modules/cinema_catalog/cinema_catalog.repository.ts 的 search）：ngram 全文索引按两个字一词，
-- 单个字原来只能 LIKE '%字%' 把这个源的全部行扫一遍再排序（线上 5 万行约 90 毫秒，抓全后翻倍）；改成只找片名以这个字开头的，加 (rule_id, folded 前 16 个字) 的前缀索引。
-- 由人工在已有的库上执行（服务启动不做 DDL）；只加索引，旧版服务不受影响。可重复执行（先查 information_schema，索引已在就跳过）。
SET @have := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'cinema_catalog' AND INDEX_NAME = 'idx_cinema_catalog_prefix');
SET @ddl := IF(@have = 0, 'ALTER TABLE cinema_catalog ADD INDEX idx_cinema_catalog_prefix (rule_id, folded(16))', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;
