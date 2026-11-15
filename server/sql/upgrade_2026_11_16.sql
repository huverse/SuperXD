-- 2026-11-16 积分到期清零只扫还有剩余的获得：原来按 idx_expire 从最早到期的扫起，剩余为 0、过期后还要留 30 天的行全都要扫一遍（随全库增长）。
-- 加一个虚拟列 due_time（还有剩余时等于到期时刻，否则为空）并建索引，清零任务只走这些行。由人工在已有的库上执行（服务启动不做 DDL）；
-- 加虚拟列是 INSTANT、建索引是 INPLACE 且不挡读写，都不重建表；新旧版服务都能跑在加过的表上，可以先执行再部署。可重复执行。

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'points_grant' AND COLUMN_NAME = 'due_time');
SET @ddl := IF(@have = 0,
  'ALTER TABLE points_grant ADD COLUMN due_time DATETIME(3) AS (IF(remaining > 0, expire_time, NULL)) VIRTUAL COMMENT ''还有剩余时等于到期时刻，否则为空（到期清零只扫这些）'', ALGORITHM=INSTANT',
  'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'points_grant' AND INDEX_NAME = 'idx_due');
SET @ddl := IF(@have = 0, 'ALTER TABLE points_grant ADD KEY idx_due (due_time), ALGORITHM=INPLACE, LOCK=NONE', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;
