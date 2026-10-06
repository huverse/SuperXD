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

-- 代签凭据包的临时信箱：只存客户端拿一次性密钥加过密的包（服务端没有密钥），取走即删，未取走的 10 分钟后由清理任务删除。
CREATE TABLE IF NOT EXISTS chaoxing_pack (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  pickup_id VARCHAR(32) NOT NULL COMMENT '取件号，12 字节随机数的 base64url',
  data VARBINARY(2048) NOT NULL COMMENT '一次性密钥加密后的代签凭据包',
  bytes INT UNSIGNED NOT NULL,
  expire_time DATETIME(3) NOT NULL,
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_pickup (pickup_id),
  KEY idx_expire (expire_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
