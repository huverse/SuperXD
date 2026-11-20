import { Injectable } from "@nestjs/common";
import { InjectRepository } from "@nestjs/typeorm";
import { Repository } from "typeorm";

import { cleanupBatch } from "src/common/relay_limits";
import { CinemaCatalogEntity } from "src/modules/cinema_catalog/cinema_catalog.entity";

export type CinemaCatalogState = {
  crawlStarted: Date | null;
  crawlPage: number;
  syncedAt: Date | null;
};

// 片名目录的存储端口：服务只依赖这个抽象。
export abstract class CinemaCatalogRepository {
  // 按折叠写法查编号：两个字起走 ngram 全文索引（子串）；完全一样的在前、开头一样的其次、短的在前。
  // [人工决策-2026-11-20 20:37:08] 单个字只找片名以这个字开头的（用户选定，没选「单字不搜这个源」与「照旧找包含」）：走 (rule_id, folded 前缀) 索引，
  // 不再 LIKE '%字%' 把这个源的全部行扫一遍（线上 5 万行约 90 毫秒，抓全后翻倍、并发一高拖慢小内存的库）；代价是搜「爱」找不到「真爱」。
  abstract search(
    ruleId: string,
    folded: string,
    limit: number,
  ): Promise<string[]>;
  // 一批写进去（同编号的改名覆盖），多行 INSERT 一条 SQL。
  abstract upsert(
    ruleId: string,
    entries: { source: string; folded: string }[],
    now: Date,
  ): Promise<void>;
  abstract count(ruleId: string): Promise<number>;
  abstract state(ruleId: string): Promise<CinemaCatalogState | null>;
  abstract saveState(
    ruleId: string,
    state: CinemaCatalogState,
    now: Date,
  ): Promise<void>;
  // 删掉规则包里已经没有的源（目录与进度），分批，返回删的行数；删了行就整理一次表（见实现）。
  abstract dropExcept(keep: string[]): Promise<number>;
}

const escapeLike = (text: string) =>
  text.replace(/[\\%_]/g, (char) => `\\${char}`);

@Injectable()
export class TypeormCinemaCatalogRepository extends CinemaCatalogRepository {
  constructor(
    @InjectRepository(CinemaCatalogEntity)
    private readonly catalog: Repository<CinemaCatalogEntity>,
  ) {
    super();
  }

  async search(ruleId: string, folded: string, limit: number) {
    const rows = (
      [...folded].length < 2
        ? // 优化器把前缀命中的行数估高、嫌回表贵，会改走 (rule_id, source) 把整个源扫一遍（6 万行合成数据实测 49 毫秒，强制走前缀索引 6 毫秒），所以写明索引。
          await this.catalog.query(
            "SELECT source FROM cinema_catalog FORCE INDEX (idx_cinema_catalog_prefix) WHERE rule_id = ? AND folded LIKE ? ORDER BY folded = ? DESC, CHAR_LENGTH(folded), id LIMIT ?",
            [ruleId, `${escapeLike(folded)}%`, folded, limit],
          )
        : await this.catalog.query(
            "SELECT source FROM cinema_catalog WHERE rule_id = ? AND MATCH(folded) AGAINST(? IN BOOLEAN MODE) ORDER BY folded = ? DESC, folded LIKE ? DESC, CHAR_LENGTH(folded), id LIMIT ?",
            [
              ruleId,
              `"${folded.replace(/"/g, "")}"`,
              folded,
              `${escapeLike(folded)}%`,
              limit,
            ],
          )
    ) as { source: string }[];
    return rows.map((row) => row.source);
  }

  async upsert(
    ruleId: string,
    entries: { source: string; folded: string }[],
    now: Date,
  ) {
    if (entries.length === 0) return;
    await this.catalog.query(
      "INSERT INTO cinema_catalog (rule_id, source, folded, create_time, update_time) VALUES ? ON DUPLICATE KEY UPDATE folded = VALUES(folded), update_time = VALUES(update_time)",
      [entries.map((entry) => [ruleId, entry.source, entry.folded, now, now])],
    );
  }

  async count(ruleId: string) {
    const [row] = (await this.catalog.query(
      "SELECT COUNT(*) AS count FROM cinema_catalog WHERE rule_id = ?",
      [ruleId],
    )) as { count: string | number }[];
    return Number(row.count);
  }

  async state(ruleId: string) {
    const [row] = (await this.catalog.query(
      "SELECT crawl_started AS crawlStarted, crawl_page AS crawlPage, synced_at AS syncedAt FROM cinema_catalog_state WHERE rule_id = ?",
      [ruleId],
    )) as {
      crawlStarted: Date | null;
      crawlPage: number;
      syncedAt: Date | null;
    }[];
    if (row === undefined) return null;
    return {
      crawlStarted:
        row.crawlStarted === null ? null : new Date(row.crawlStarted),
      crawlPage: Number(row.crawlPage),
      syncedAt: row.syncedAt === null ? null : new Date(row.syncedAt),
    };
  }

  async saveState(ruleId: string, state: CinemaCatalogState, now: Date) {
    await this.catalog.query(
      "INSERT INTO cinema_catalog_state (rule_id, crawl_started, crawl_page, synced_at, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE crawl_started = VALUES(crawl_started), crawl_page = VALUES(crawl_page), synced_at = VALUES(synced_at), update_time = VALUES(update_time)",
      [ruleId, state.crawlStarted, state.crawlPage, state.syncedAt, now, now],
    );
  }

  async dropExcept(keep: string[]) {
    let removed = 0;
    const where = keep.length === 0 ? "" : "WHERE rule_id NOT IN (?)";
    await this.catalog.query(
      `DELETE FROM cinema_catalog_state ${where}`,
      keep.length === 0 ? [] : [keep],
    );
    for (let round = 0; round < 1000; round++) {
      const result = (await this.catalog.query(
        `DELETE FROM cinema_catalog ${where} LIMIT ${cleanupBatch}`,
        keep.length === 0 ? [] : [keep],
      )) as { affectedRows: number };
      removed += result.affectedRows;
      if (result.affectedRows < cleanupBatch) break;
    }
    // InnoDB 的全文索引把删掉的行留在待清理列表里，之后每次全文搜索都要滤一遍（测试库删了 6 万行后，一次搜索连同请求从约 1 毫秒变成二十多毫秒）。
    // 拿掉一个源很少发生，删了行就重建一次表：带全文索引的表重建时照常能读、写入要等（写入只来自这个定时任务自己）。
    if (removed > 0) await this.catalog.query('OPTIMIZE TABLE cinema_catalog');
    return removed;
  }
}
