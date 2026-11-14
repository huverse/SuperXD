-- 2026-11-15 游乐场挑战重做（碎片、门、终章、加试题与预计用时，人工决策见客户端 lib/playground/challenge/challenge_rules.dart 的 11-14 23:11 那条）。
-- 由人工在已有的库上执行一次（服务启动不做 DDL），先执行本文件、传新题库与配置，再部署新版服务；可重复执行。

-- 预计用时的回调（见 src/modules/challenge/challenge_pace.ts）：每个游戏每周每档的过关次数（档 = log2(分段用时 ÷ 题库预计用时) × 4 取整，−12 到 12），
-- 行数不超过 游戏数 × 12 周 × 25 档；满 12 周的由每小时一次的清理任务删除。只是分析用的计数，不进备份。
CREATE TABLE IF NOT EXISTS challenge_pace (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  game VARCHAR(24) NOT NULL,
  week CHAR(10) NOT NULL COMMENT '业务时区的周一 YYYY-MM-DD',
  bucket TINYINT NOT NULL,
  count INT UNSIGNED NOT NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_challenge_pace (game, week, bucket),
  KEY idx_week (week)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 旧格式（钥匙填空）的局：新版服务认不出它的计划，部署前把还在进行中的都按提前结束收掉（线上只有测试局）。
UPDATE challenge_run SET active = NULL, ending = 'ended', end_time = UTC_TIMESTAMP(3), update_time = UTC_TIMESTAMP(3) WHERE active = 1;
