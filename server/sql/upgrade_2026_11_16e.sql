-- 2026-11-16 分批更新的健康回报、自动暂停与意见反馈（人工决策见 src/modules/app_health/app_health_rules.ts）：三张新表，都不带账号与设备号。
-- 由人工在已有的库上执行（服务启动不做 DDL）；只建表，旧版服务不碰它们，可以先执行再部署。可重复执行。
-- 健康回报的按日汇总：渠道、平台、版本、校园日各一行，只有份数与致命份数；保留 90 天。
CREATE TABLE IF NOT EXISTS app_health_daily (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  channel VARCHAR(32) NOT NULL,
  platform VARCHAR(8) NOT NULL COMMENT 'android 或 ios',
  version_code INT UNSIGNED NOT NULL,
  day DATE NOT NULL COMMENT '校园日',
  reports INT UNSIGNED NOT NULL COMMENT '回报份数',
  fatal INT UNSIGNED NOT NULL COMMENT '其中那天有致命错误的份数',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_health_day (channel, day, version_code, platform),
  KEY idx_day (day)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 自动暂停：渠道加版本一行，paused 为 1 停着、0 已解除（之后不再自动停这一版）；保留 180 天。
CREATE TABLE IF NOT EXISTS app_release_pause (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  channel VARCHAR(32) NOT NULL,
  version_code INT UNSIGNED NOT NULL,
  paused TINYINT UNSIGNED NOT NULL,
  reason VARCHAR(200) NOT NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_channel_version (channel, version_code),
  KEY idx_create (create_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 新版本的匿名意见：好或不好与一句话；保留 90 天。
CREATE TABLE IF NOT EXISTS app_feedback (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  channel VARCHAR(32) NOT NULL,
  platform VARCHAR(8) NOT NULL,
  version_code INT UNSIGNED NOT NULL,
  good TINYINT UNSIGNED NOT NULL COMMENT '1 好，0 不好',
  text VARCHAR(200) NOT NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  KEY idx_channel_version (channel, version_code, id),
  KEY idx_create (create_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
