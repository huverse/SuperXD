-- 2026-10-23 节日抽奖：建 reward_campaign、reward_prize、reward_draw 三张表。由人工在已有的库上执行一次（服务启动不做 DDL），先执行本文件再部署新版服务。

-- 节日抽奖（人工决策见 src/modules/reward/reward_odds.ts）：一次活动一行，编号与客户端的节日编号一致；起止为 UTC 绝对时刻。
-- 活动结束 30 天后由清理任务连同奖品与抽签记录分批删除。
CREATE TABLE IF NOT EXISTS reward_campaign (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  campaign_key VARCHAR(64) NOT NULL COMMENT '活动编号，同客户端的节日编号，如 spring-2027',
  starts_at DATETIME(3) NOT NULL,
  ends_at DATETIME(3) NOT NULL,
  mode VARCHAR(16) NOT NULL COMMENT 'uniform 平权，weighted 按活跃度加权',
  base_chance DECIMAL(7,6) NOT NULL COMMENT '权重为 1 的人一次抽中的概率',
  max_weight DECIMAL(5,2) NOT NULL COMMENT '加权上限：最活跃的人是新用户的几倍，平权时为 1',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_campaign_key (campaign_key),
  KEY idx_ends (ends_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 奖品：维护者导入的支付宝口令或二维码内容，一份发给一个人（draw_id 为发给了哪次抽签）。
CREATE TABLE IF NOT EXISTS reward_prize (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  campaign_id BIGINT UNSIGNED NOT NULL,
  kind VARCHAR(16) NOT NULL COMMENT 'password 口令，qrcode 二维码内容',
  content VARCHAR(1024) NOT NULL,
  note VARCHAR(200) NOT NULL DEFAULT '' COMMENT '附言，显示在奖品下面',
  draw_id BIGINT UNSIGNED NULL COMMENT '发给了哪次抽签，没发出为空',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  KEY idx_campaign_draw (campaign_id, draw_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 抽签记录：每次活动每个参与号一行（参与号只存 sha256），重复请求返回同一个结果，抽不中的也记，防止反复重抽。
CREATE TABLE IF NOT EXISTS reward_draw (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  campaign_id BIGINT UNSIGNED NOT NULL,
  participant_hash CHAR(64) NOT NULL COMMENT '参与号的 sha256 十六进制',
  active_days TINYINT UNSIGNED NOT NULL COMMENT '客户端报的近 30 天打开过的天数',
  weight DECIMAL(5,2) NOT NULL,
  chance DECIMAL(7,6) NOT NULL,
  prize_id BIGINT UNSIGNED NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_campaign_participant (campaign_id, participant_hash)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
