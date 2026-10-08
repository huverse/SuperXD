-- 2026-10-08 代签码轮换即作废：chaoxing_pack 加作废口令哈希。由人工在已有的库上执行一次（服务启动不做 DDL）。
-- 先执行本文件再部署新版服务；老版本服务插入时不带这一列，按默认空串存，空串对不上任何口令，不影响取件。
ALTER TABLE chaoxing_pack ADD COLUMN revoke_hash VARCHAR(64) NOT NULL DEFAULT '' COMMENT '作废口令的 sha256 十六进制；口令只在投递响应里给出示方一次' AFTER expire_time;
