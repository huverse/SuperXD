-- 2026-11-18 健康回报加两项性能档位（人工决策见 src/modules/app_health/app_health_rules.ts 的 11-17 那条）：app_health_daily 加启动档与慢帧档各四档的份数，
-- launch_t0–t3（Dart 入口到首帧上屏：不到 0.5 秒、0.5–1 秒、1–2 秒、2 秒以上）与 frames_t0–t3（慢帧占比：不到 5%、5–15%、15–40%、40% 以上），默认 0（旧行与不带档位的回报不计入）。
-- 由人工在已有的库上执行（服务启动不做 DDL）；加列是 INSTANT、不重建表，旧版服务不读新列，要先执行再部署新版服务。可重复执行。
SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'app_health_daily' AND COLUMN_NAME = 'launch_t0');
SET @ddl := IF(@have = 0, 'ALTER TABLE app_health_daily ADD COLUMN launch_t0 INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''启动档 0（不到 0.5 秒）的份数'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'app_health_daily' AND COLUMN_NAME = 'launch_t1');
SET @ddl := IF(@have = 0, 'ALTER TABLE app_health_daily ADD COLUMN launch_t1 INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''启动档 1（0.5–1 秒）的份数'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'app_health_daily' AND COLUMN_NAME = 'launch_t2');
SET @ddl := IF(@have = 0, 'ALTER TABLE app_health_daily ADD COLUMN launch_t2 INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''启动档 2（1–2 秒）的份数'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'app_health_daily' AND COLUMN_NAME = 'launch_t3');
SET @ddl := IF(@have = 0, 'ALTER TABLE app_health_daily ADD COLUMN launch_t3 INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''启动档 3（2 秒以上）的份数'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'app_health_daily' AND COLUMN_NAME = 'frames_t0');
SET @ddl := IF(@have = 0, 'ALTER TABLE app_health_daily ADD COLUMN frames_t0 INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''慢帧档 0（不到 5%）的份数'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'app_health_daily' AND COLUMN_NAME = 'frames_t1');
SET @ddl := IF(@have = 0, 'ALTER TABLE app_health_daily ADD COLUMN frames_t1 INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''慢帧档 1（5–15%）的份数'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'app_health_daily' AND COLUMN_NAME = 'frames_t2');
SET @ddl := IF(@have = 0, 'ALTER TABLE app_health_daily ADD COLUMN frames_t2 INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''慢帧档 2（15–40%）的份数'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;

SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'app_health_daily' AND COLUMN_NAME = 'frames_t3');
SET @ddl := IF(@have = 0, 'ALTER TABLE app_health_daily ADD COLUMN frames_t3 INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''慢帧档 3（40% 以上）的份数'', ALGORITHM=INSTANT', 'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;
