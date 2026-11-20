-- 2026-11-20 片名目录的单字搜索走索引、连排序一起（人工决策见 src/modules/cinema_catalog/cinema_catalog.repository.ts 的 search）：ngram 全文索引按两个字一词，
-- 单个字原来只能 LIKE '%字%' 把这个源的全部行扫一遍再排序（线上 5 万行约 90 毫秒，抓全后翻倍）；改成只找片名以这个字开头的。
-- 加两个存储的生成列：首字 head 与片名长度 folded_length，索引 (rule_id, head, folded_length)（InnoDB 二级索引自带主键 id）：
-- 查询按 rule_id、head 定位后按长度、编号直接从索引里取前 20 条，不排序，热门首字也只读 20 行；片名就是这一个字的长度为 1，自然排最前。
-- 这个文件线上还没执行过就改写了（最早写的是 (rule_id, folded 前 16 字) 前缀索引，Codex 指出排序仍要把首字相同的全读出来，6 万行里 3 万行同首字时约 30 毫秒）；
-- 本机与测试库执行过旧版的，这里先删掉那个前缀索引。
-- 由人工在已有的库上执行（服务启动不做 DDL）；带全文索引的表加存储列会整表复制（表小，几秒），旧版服务不读这两列。可重复执行（先查 information_schema）。
SET @have := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'cinema_catalog' AND INDEX_NAME = 'idx_cinema_catalog_prefix');
SET @ddl := IF(@have > 0, 'ALTER TABLE cinema_catalog DROP INDEX idx_cinema_catalog_prefix', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'cinema_catalog' AND COLUMN_NAME = 'head');
SET @ddl := IF(@have = 0,
  'ALTER TABLE cinema_catalog ADD COLUMN head VARCHAR(1) GENERATED ALWAYS AS (LEFT(folded, 1)) STORED COMMENT ''片名折叠写法的第一个字（单字搜索用）'' AFTER folded, ADD COLUMN folded_length SMALLINT UNSIGNED GENERATED ALWAYS AS (CHAR_LENGTH(folded)) STORED COMMENT ''片名折叠写法的字数（单字搜索按它排）'' AFTER head',
  'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'cinema_catalog' AND INDEX_NAME = 'idx_cinema_catalog_head');
SET @ddl := IF(@have = 0, 'ALTER TABLE cinema_catalog ADD INDEX idx_cinema_catalog_head (rule_id, head, folded_length)', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;
