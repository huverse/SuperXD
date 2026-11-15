-- 2026-11-15 应用账号改为自己的账号体系（用户名加密码，人工决策见 src/modules/account/account.service.ts）：
-- 用户选「老账号全部重新注册」，所以先清掉 11-13 起用教务核对登录的全部应用账号与挂在账号下的数据（同注销：积分、挑战、解锁、私信设备连同它的好友与信箱、
-- 诊断包的认领记录，诊断包文件照旧 30 天后删），再删掉不再用的学号哈希表、给账号表加用户名与两个哈希。
-- 由人工在已有的库上执行一次（服务启动不做 DDL），先执行本文件再部署新版服务；旧版服务在这之后登录会失败，切换要紧接着做。可重复执行。

DELETE FROM friendship WHERE owner_device_id IN (SELECT device_id FROM account_social) OR peer_device_id IN (SELECT device_id FROM account_social);
DELETE FROM message WHERE recipient_device_id IN (SELECT device_id FROM account_social);
DELETE FROM device WHERE device_id IN (SELECT device_id FROM account_social) OR device_id IN (SELECT device_id FROM account_device);
DELETE FROM account_social;
DELETE FROM account_unlock;
DELETE FROM challenge_run;
DELETE FROM challenge_best;
DELETE FROM points_entry;
DELETE FROM points_grant;
DELETE FROM diagnostic_upload;
DELETE FROM account_device;
DELETE FROM app_account;
DROP TABLE IF EXISTS account_identity;

-- 加列：表已清空，NOT NULL 不用默认值；重复执行时列已在就跳过（information_schema 判断后拼语句）。
SET @have := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'app_account' AND COLUMN_NAME = 'username');
SET @ddl := IF(@have = 0,
  'ALTER TABLE app_account ADD COLUMN username VARCHAR(20) NOT NULL COMMENT ''用户名，小写的规范写法，3–20 位字母数字下划线'' AFTER account_id, ADD COLUMN password_hash VARCHAR(160) NOT NULL COMMENT ''scrypt$N$r$p$盐$哈希'' AFTER username, ADD COLUMN recovery_hash VARCHAR(160) NOT NULL COMMENT ''恢复码的 scrypt 哈希，格式同上'' AFTER password_hash, ADD UNIQUE KEY uk_username (username)',
  'SELECT 1');
PREPARE statement FROM @ddl;
EXECUTE statement;
DEALLOCATE PREPARE statement;
