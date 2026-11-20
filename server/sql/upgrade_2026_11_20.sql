-- 2026-11-20 电影院片名目录型源的服务端索引（人工决策见 src/modules/cinema_catalog/cinema_catalog.service.ts）：采集站不给按片名搜索的源（如 wsy），
-- 由中转每小时从源取片名补进这张表，手机搜索时把片名发来、这里查出编号返回；只存片名的折叠写法与编号（源上公开的目录，不含任何用户信息），搜索词不落库。
-- cinema_catalog_state 每个源一行，记抓全的起点、抓到第几页（断了下次接着抓）与增量补到的时刻。
-- 全文索引用 MySQL 自带的 ngram 分词（两个字一词，中文按子串查）；建表前关掉默认停用词，不然 the、for 这类英文片名片段查不到。
-- 由人工在已有的库上执行（服务启动不做 DDL）；只新建表，旧版服务不读它。可重复执行。
SET SESSION innodb_ft_enable_stopword = OFF;

CREATE TABLE IF NOT EXISTS cinema_catalog (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  rule_id VARCHAR(32) NOT NULL COMMENT '片源规则包 catalogRules 里的规则编号',
  source VARCHAR(64) NOT NULL COMMENT '这个源里的影片编号',
  folded VARCHAR(255) NOT NULL COMMENT '片名的折叠写法（去空白、全角折半角、小写），只用来查',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_cinema_catalog (rule_id, source),
  FULLTEXT KEY ft_cinema_catalog (folded) WITH PARSER ngram
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE IF NOT EXISTS cinema_catalog_state (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  rule_id VARCHAR(32) NOT NULL,
  crawl_started DATETIME(3) NULL COMMENT '正在抓全的这一轮从什么时刻起（UTC），没在抓全为空',
  crawl_page INT UNSIGNED NOT NULL DEFAULT 0 COMMENT '这一轮已经抓到第几页',
  synced_at DATETIME(3) NULL COMMENT '抓全或增量补到的时刻（UTC），还没抓全过为空',
  create_time DATETIME(3) NOT NULL,
  update_time DATETIME(3) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_cinema_catalog_state (rule_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
