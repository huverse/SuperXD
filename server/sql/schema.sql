-- SuperXD 中转服务表结构 v1。由人工执行，服务启动时不做任何 DDL。
-- 无外键，表间关联全靠代码；时间一律 UTC（DATETIME(3)）。

CREATE TABLE IF NOT EXISTS device (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  device_id VARCHAR(32) NOT NULL COMMENT 'base64url(sha256(签名公钥)前16字节)',
  sign_public_key VARCHAR(64) NOT NULL COMMENT 'Ed25519 公钥 base64url',
  box_public_key VARCHAR(64) NOT NULL COMMENT 'X25519 公钥 base64url（只存档，服务端不加解密）',
  last_seen_time DATETIME(3) NOT NULL COMMENT '最后活跃，每小时最多写一次；400 天未活跃删除',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_device_id (device_id),
  KEY idx_last_seen (last_seen_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 好友关系按方向各存一行：查“我的好友”与“能否给对方发”都走 uk_owner_peer 前缀。每设备最多 500 个。
CREATE TABLE IF NOT EXISTS friendship (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  owner_device_id VARCHAR(32) NOT NULL,
  peer_device_id VARCHAR(32) NOT NULL,
  moved_from VARCHAR(32) NULL COMMENT '对方的私信换到了 peer 这台新设备，owner 还认得的旧设备号；owner 确认后清空',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_owner_peer (owner_device_id, peer_device_id),
  KEY idx_peer (peer_device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 信箱：只存密文。取走确认即删；未取走的 30 天后由清理任务按 idx_expire 分批删除。每设备待取最多 1000 条。
CREATE TABLE IF NOT EXISTS message (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  recipient_device_id VARCHAR(32) NOT NULL,
  sender_device_id VARCHAR(32) NOT NULL,
  client_id VARCHAR(36) NOT NULL COMMENT '发送方生成的消息号，重发幂等',
  envelope MEDIUMBLOB NOT NULL COMMENT '端到端密文，单条不超过 256KB',
  expire_time DATETIME(3) NOT NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_sender_client (sender_device_id, client_id),
  KEY idx_recipient (recipient_device_id, id),
  KEY idx_expire (expire_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 代签凭据包的临时信箱：只存客户端拿一次性密钥加过密的包（服务端没有密钥），取走即删；10 分钟过期即取不到，清理任务每 10 分钟一轮删除过期的。
-- 已有的库按 sql/upgrade_2026_10_08.sql 加 revoke_hash 列。
CREATE TABLE IF NOT EXISTS chaoxing_pack (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  pickup_id VARCHAR(32) NOT NULL COMMENT '取件号，12 字节随机数的 base64url',
  data VARBINARY(2048) NOT NULL COMMENT '一次性密钥加密后的代签凭据包',
  bytes INT UNSIGNED NOT NULL,
  expire_time DATETIME(3) NOT NULL,
  revoke_hash VARCHAR(64) NOT NULL DEFAULT '' COMMENT '作废口令的 sha256 十六进制；口令只在投递响应里给出示方一次',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_pickup (pickup_id),
  KEY idx_expire (expire_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 节日抽奖（人工决策见 src/modules/reward/reward_odds.ts）：一次活动一行，编号与客户端的节日编号一致；起止为 UTC 绝对时刻。
-- 活动结束 30 天后由清理任务连同奖品与抽签记录分批删除。已有的库按 sql/upgrade_2026_10_23.sql 建这三张表。
CREATE TABLE IF NOT EXISTS reward_campaign (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  campaign_key VARCHAR(64) NOT NULL COMMENT '活动编号，同客户端的节日编号，如 spring-2027',
  starts_at DATETIME(3) NOT NULL,
  ends_at DATETIME(3) NOT NULL,
  mode VARCHAR(16) NOT NULL COMMENT 'uniform 平权，weighted 按活跃度加权',
  base_chance DECIMAL(7,6) NOT NULL COMMENT '权重为 1 的人一次抽中的概率',
  max_weight DECIMAL(5,2) NOT NULL COMMENT '加权上限：最活跃的人是新用户的几倍，平权时为 1',
  distribution VARCHAR(8) NOT NULL DEFAULT 'lottery' COMMENT 'lottery 抽签，all 有资格就发（发完为止）',
  audience VARCHAR(8) NOT NULL DEFAULT 'everyone' COMMENT 'everyone 人人可参加，list 只有 reward_audience 名单里的应用账号',
  min_account_days SMALLINT UNSIGNED NOT NULL DEFAULT 7 COMMENT '应用账号建立满几天才能参加',
  min_level TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '最低积分等级 0–5',
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
  tier TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '金额档：0 普通，数越大金额越高（抽中后大额档按积分等级加权挑）',
  kind VARCHAR(16) NOT NULL COMMENT 'password 口令，qrcode 二维码内容',
  content VARCHAR(1024) NOT NULL,
  note VARCHAR(200) NOT NULL DEFAULT '' COMMENT '附言，显示在奖品下面',
  draw_id BIGINT UNSIGNED NULL COMMENT '发给了哪次抽签，没发出为空',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  KEY idx_campaign_tier_draw (campaign_id, tier, draw_id)
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

-- 名单活动的名单：一个应用账号一行，由 reward_admin audience 按用户名导入；随活动删除（活动结束 30 天后）、随账号删除。
CREATE TABLE IF NOT EXISTS reward_audience (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  campaign_id BIGINT UNSIGNED NOT NULL,
  account_id VARCHAR(32) NOT NULL COMMENT '应用账号号',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_campaign_account (campaign_id, account_id),
  KEY idx_account (account_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 应用账号（人工决策见 src/modules/account/account.service.ts）：自己的账号体系，用户名加密码；对外只有随机账号号与用户名，
-- 密码与恢复码只存 scrypt 哈希（src/modules/account/account_keys.ts）。400 天没有任何设备的签名请求即连同下面的设备登记删除。
CREATE TABLE IF NOT EXISTS app_account (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL COMMENT '随机账号号 base64url，客户端拿它做灰度分桶',
  username VARCHAR(20) NOT NULL COMMENT '用户名，小写的规范写法，3–20 位字母数字下划线',
  password_hash VARCHAR(160) NOT NULL COMMENT 'scrypt$N$r$p$盐$哈希',
  recovery_hash VARCHAR(160) NOT NULL COMMENT '恢复码的 scrypt 哈希，格式同上',
  last_seen_time DATETIME(3) NOT NULL COMMENT '最后活跃：登录、查看或账号下任一设备的签名请求（每台每小时最多记一次）',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_account_id (account_id),
  UNIQUE KEY uk_username (username),
  KEY idx_last_seen (last_seen_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 账号登录在哪些设备密钥上：一把密钥只属于一个账号，每个账号最多 20 把；设备删除时连带删除。
CREATE TABLE IF NOT EXISTS account_device (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  device_id VARCHAR(32) NOT NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_device (device_id),
  KEY idx_account (account_id, update_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 已注销账号的设备密钥（人工决策见 src/modules/account/account.service.ts 的 remove）：注销时每把密钥一行，这些密钥再来回 ACCOUNT_DELETED；
-- 只有设备号与时刻，不记账号号；保留 400 天（之后这些设备也早被不活跃清理删掉），由账号的清理任务每小时分批删。
CREATE TABLE IF NOT EXISTS account_tombstone (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  device_id VARCHAR(32) NOT NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_device (device_id),
  KEY idx_create (create_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 积分每笔获得一行（人工决策见 src/modules/points/points.service.ts）：满 12 个月过期；余额 = 没过期的 remaining 之和；剩余为 0 且过期满 30 天删除。
CREATE TABLE IF NOT EXISTS points_grant (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  amount INT UNSIGNED NOT NULL,
  remaining INT UNSIGNED NOT NULL,
  source VARCHAR(16) NOT NULL COMMENT '来源，现在只有 challenge',
  source_key VARCHAR(64) NOT NULL COMMENT '幂等键：同一来源同一个键只记一次（挑战是这一局的编号）',
  expire_time DATETIME(3) NOT NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  due_time DATETIME(3) AS (IF(remaining > 0, expire_time, NULL)) VIRTUAL COMMENT '还有剩余时等于到期时刻，否则为空（到期清零只扫这些）',
  PRIMARY KEY (id),
  UNIQUE KEY uk_source (source, source_key),
  KEY idx_account_expire (account_id, expire_time),
  KEY idx_expire (expire_time),
  KEY idx_due (due_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 积分流水：只增，满 13 个月删除。
CREATE TABLE IF NOT EXISTS points_entry (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  kind VARCHAR(8) NOT NULL COMMENT 'earn 获得、expire 过期、spend 花费、refund 退回',
  amount INT NOT NULL COMMENT '正数加、负数减',
  note VARCHAR(64) NOT NULL COMMENT '给用户看的说明',
  ref VARCHAR(64) NOT NULL COMMENT '关联：挑战局编号、过期的那笔获得',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  KEY idx_account (account_id, id),
  KEY idx_time (create_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 账号记过的解锁（规则见 src/modules/unlock/unlock_rules.ts）：花积分买的（buy）与按等级加权抽签抽中的（drawn），一个账号一项一行；
-- 随账号删除；服务公开 30 天后、或下架退回积分后由每小时一次的清理任务删除。
CREATE TABLE IF NOT EXISTS account_unlock (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  unlock_id VARCHAR(64) NOT NULL COMMENT '灰度配置 unlocks 里的编号，如 game.sudoku',
  source VARCHAR(8) NOT NULL COMMENT 'buy 花积分买的，drawn 抽签抽中的',
  price INT UNSIGNED NOT NULL COMMENT '付的积分，抽中的为 0（下架时按它退回）',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_account_unlock (account_id, unlock_id),
  KEY idx_unlock (unlock_id, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 挑战的一局（人工决策见客户端 lib/playground/challenge/challenge_rules.dart）：计划与进度是 JSON 文本；active 进行中为 1、结算后为空，
-- (account_id, active) 唯一，一个账号同时只有一局进行中。结束满 30 天删除。
CREATE TABLE IF NOT EXISTS challenge_run (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  run_id VARCHAR(32) NOT NULL,
  account_id VARCHAR(32) NOT NULL,
  challenge_id VARCHAR(64) NOT NULL,
  active TINYINT NULL,
  deadline DATETIME(3) NOT NULL,
  plan MEDIUMTEXT NOT NULL COMMENT '关卡图、题面、钥匙与计分参数快照',
  progress TEXT NOT NULL COMMENT '每关的状态、解锁与过关时刻、错交次数',
  ending VARCHAR(8) NULL COMMENT 'cleared、stuck、timeout、ended',
  points INT UNSIGNED NULL,
  awarded INT UNSIGNED NULL,
  end_time DATETIME(3) NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_run (run_id),
  UNIQUE KEY uk_account_active (account_id, active),
  KEY idx_active_deadline (active, deadline),
  KEY idx_end_time (end_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 每个账号每个挑战的最好成绩：重复挑战只补超过它的差额；挑战结束满 400 天删除。
CREATE TABLE IF NOT EXISTS challenge_best (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  challenge_id VARCHAR(64) NOT NULL,
  points INT UNSIGNED NOT NULL,
  run_id VARCHAR(32) NOT NULL,
  ends_at DATETIME(3) NOT NULL COMMENT '挑战的开放结束时刻',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_account_challenge (account_id, challenge_id),
  KEY idx_ends (ends_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 预计用时的回调（见 src/modules/challenge/challenge_pace.ts）：每个游戏每周每档的过关次数，满 12 周删除；只是分析用的计数，不进备份。
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

-- 应用账号的私信设备（人工决策见客户端 lib/social/social_service.dart 文件头）：一个账号同一时刻一台，接管时改指新设备；删设备与注销账号时删。行数以账号数为界。
CREATE TABLE IF NOT EXISTS account_social (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id VARCHAR(32) NOT NULL,
  device_id VARCHAR(32) NOT NULL COMMENT '私信设备号',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_account (account_id),
  UNIQUE KEY uk_device (device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 灰度点名（人工决策见客户端 lib/domain/rollout.dart 的 11-16 那条）：开发者用管理命令 flag_admin 把某个开关单独开给某个应用账号，名单只在服务器；
-- 手机登录着应用账号时签名来问 GET /v1/flags/mine。随账号删除，到期的每天清。
CREATE TABLE IF NOT EXISTS rollout_target (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  flag_id VARCHAR(64) NOT NULL COMMENT '开关编号，同灰度配置里的 id',
  account_id VARCHAR(32) NOT NULL COMMENT '应用账号号',
  expires_at DATETIME(3) NULL COMMENT '点到什么时刻，为空是一直开到撤销',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_flag_account (flag_id, account_id),
  KEY idx_account_expires (account_id, expires_at),
  KEY idx_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- 分批更新的健康回报、自动暂停与意见反馈（人工决策见 src/modules/app_health/app_health_rules.ts），都不带账号与设备号。
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
