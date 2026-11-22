import { HttpStatus, Injectable, Logger } from '@nestjs/common';

import { rateSubjectOf } from 'src/common/client_ip';
import { fetchText } from 'src/common/outbound_http';
import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import {
  cinemaCatalogAllHours,
  cinemaCatalogConcurrency,
  cinemaCatalogEntryLimit,
  cinemaCatalogHits,
  cinemaCatalogIncrementalDays,
  cinemaCatalogPageAttempts,
  cinemaCatalogPageMaxBytes,
  cinemaCatalogBatchPages,
  cinemaCatalogRunMs,
  cinemaCatalogPageTimeoutMs,
  cinemaCatalogSearchPerHour,
} from 'src/common/relay_limits';
import { CinemaCatalogRepository } from 'src/modules/cinema_catalog/cinema_catalog.repository';
import { CinemaCatalogRule, CinemaCatalogSource, catalogPageUrl, cinemaFold, parseCatalogPage } from 'src/modules/cinema_catalog/cinema_catalog_source';

// [人工决策-2026-11-20 16:40:37] 片名目录放服务器（用户选定，取代同日早些时候的「底包下到手机」；用户澄清「减少服务端压力」指流量，另要求应用体积不做不必要的增长）：
// 采集站把按片名搜索关掉的源（如 wsy），由中转维护它的片名目录：每小时向源取最近更新的片名补进 cinema_catalog（只存编号与片名的折叠写法），
// 手机搜这个源时把片名 POST 过来（不进地址，接入层的访问日志里也没有），这里用 ngram 全文索引查出最多 cinemaCatalogHits 个编号返回，
// 手机再拿编号直接向源取详情与选集，视频照旧不经中转。搜索词不落库、不写日志；一次搜索来回几 KB，手机上不下载、不占空间。
// 隐私政策随之升修订 12（用户选定）：第六节写明搜这类源时片名会发到开发者服务器、不保存。
// 抓取：第一次（或离上次超过 cinemaCatalogIncrementalDays 天）按 @hours 填大数抓全，一轮最多 cinemaCatalogPagesPerRun 页、断了下一轮从抓到的页接着抓，
// 抓全的起点记成补到的时刻；之后每轮按离上次多少小时（多补一小时）只取前几页。这是中转自己的后台任务，一页最多试 cinemaCatalogPageAttempts 次，
// 不受客户端「不自动重试」的约束；源连不上就停在这一轮，下一轮再来。
// 11-20 晚：一轮改按时间预算 cinemaCatalogRunMs 跑（上游深分页越往后越慢，按页数限的第一轮 3000 页跑了近 3 小时、超过锁的时限），上面写的页数上限不再用。
// [人工决策-2026-11-22 14:03:26] 改上面「之后每轮只取前几页」（11-22 Codex 复核，用户选「分轮补完」）：增量原来最多取 50 页、之后照样把同步时刻推到现在，
// 中转停了几天或上游批量更新时超出的那些永远漏掉（增量每小时刷新同步时刻，30 天重新抓全也就永远不会来）。现在增量与抓全走同一套：
// 按离上次多少小时（多补一小时）取这个时间窗的全部页，一轮受同样的时间预算，没取完记下取到第几页、下一轮接着取，取完才把同步时刻推到这一串开始的时刻。
// 一页回的不是结果列表（HTTP 200 的「服务器繁忙」）算这一页失败（parseCatalogPage），不当成空页、不推进进度。
@Injectable()
export class CinemaCatalogService {
  private readonly logger = new Logger('CinemaCatalog');

  constructor(
    private readonly source: CinemaCatalogSource,
    private readonly catalog: CinemaCatalogRepository,
    private readonly limiter: RateLimiter,
  ) {}

  async search(ip: string, ruleId: string, keyword: string): Promise<string[]> {
    const retryAfter = await this.limiter.hit('cinema_catalog', rateSubjectOf(ip), cinemaCatalogSearchPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '搜索过于频繁', { retryAfter });
    if (!(await this.source.rules()).some((rule) => rule.id === ruleId)) throw new RelayError(RelayCode.catalogNotFound, HttpStatus.NOT_FOUND, '没有这个片名目录');
    const folded = cinemaFold(keyword);
    return folded === '' ? [] : this.catalog.search(ruleId, folded, cinemaCatalogHits);
  }

  // 定时任务调：规则包里的每个目录型源抓一轮，再删掉已经没有的源。一个源出错不影响别的源。budgetMs 是这一轮抓全最多跑多久（测试里调小）。
  async sync(now = new Date(), budgetMs = cinemaCatalogRunMs) {
    let rules: CinemaCatalogRule[];
    try {
      rules = await this.source.rules();
    } catch (error) {
      console.error(error);
      this.logger.error(`[CinemaCatalog] action=rules errorType=${error instanceof Error ? error.constructor.name : typeof error}`);
      return;
    }
    for (const rule of rules) {
      try {
        await this.crawl(rule, now, budgetMs);
      } catch (error) {
        console.error(error);
        this.logger.error(`[CinemaCatalog] action=crawl rule=${rule.id} errorType=${error instanceof Error ? error.constructor.name : typeof error}`);
      }
    }
    const removed = await this.catalog.dropExcept(rules.map((rule) => rule.id));
    if (removed > 0) this.logger.warn(`[CinemaCatalog] action=drop removed=${removed} hint=低峰时手动 OPTIMIZE TABLE cinema_catalog`);
  }

  // 抓全（第一次或离上次超过 cinemaCatalogIncrementalDays 天，@hours 填大数）与增量（按离上次多少小时、多补一小时）同一套分轮接续，见文件头。
  // 增量的时间窗按没推进的同步时刻算，接着取的几轮里窗口只往新的一头长，新进来的排在前面、只会让后面的页重复几条，不会漏。
  async crawl(rule: CinemaCatalogRule, now: Date, budgetMs = cinemaCatalogRunMs) {
    const state = await this.catalog.state(rule.id);
    const syncedAt = state?.syncedAt ?? null;
    const stale = syncedAt == null || now.getTime() - syncedAt.getTime() > cinemaCatalogIncrementalDays * 86400_000;
    const hours = stale ? cinemaCatalogAllHours : Math.ceil((now.getTime() - syncedAt.getTime()) / 3600_000) + 1;
    return this.crawlPages(rule, hours, state?.crawlStarted ?? now, state?.crawlStarted != null ? state.crawlPage : 0, syncedAt, now, budgetMs);
  }

  // 从 done 页之后接着取，一批 cinemaCatalogBatchPages 页、按 cinemaCatalogConcurrency 路取，每批写库并记下取到第几页；
  // 过了 budgetMs 就停在批与批之间（下一轮接着取）；取完把这一串开始的时刻 started 记成同步时刻。
  private async crawlPages(rule: CinemaCatalogRule, hours: number, started: Date, done: number, syncedAt: Date | null, now: Date, budgetMs: number) {
    const deadline = Date.now() + budgetMs;
    const first = await this.page(rule, hours, done + 1);
    let pageCount = first.pageCount, page = done + 1, added = await this.store(rule.id, first.entries, now);
    await this.catalog.saveState(rule.id, { crawlStarted: started, crawlPage: page, syncedAt }, now);
    while (page < pageCount && Date.now() < deadline) {
      const batch = Array.from({ length: Math.min(cinemaCatalogBatchPages, pageCount - page) }, (_, index) => page + 1 + index);
      const results: Awaited<ReturnType<CinemaCatalogService['page']>>[] = [];
      for (let start = 0; start < batch.length; start += cinemaCatalogConcurrency) {
        results.push(...(await Promise.all(batch.slice(start, start + cinemaCatalogConcurrency).map((number) => this.page(rule, hours, number)))));
      }
      added += await this.store(rule.id, results.flatMap((result) => result.entries), now);
      page = batch[batch.length - 1];
      pageCount = Math.max(pageCount, ...results.map((result) => result.pageCount));
      await this.catalog.saveState(rule.id, { crawlStarted: started, crawlPage: page, syncedAt }, now);
    }
    const finished = page >= pageCount;
    if (finished) await this.catalog.saveState(rule.id, { crawlStarted: null, crawlPage: 0, syncedAt: started }, now);
    this.logger.log(`[CinemaCatalog] action=crawl rule=${rule.id} hours=${hours} pages=${page}/${pageCount} entries=${added} finished=${finished}`);
  }

  // 取一页，最多试 cinemaCatalogPageAttempts 次（隔 2、4 秒）。
  private async page(rule: CinemaCatalogRule, hours: number, page: number) {
    for (let attempt = 1; ; attempt++) {
      try {
        const raw = await fetchText(catalogPageUrl(rule, { hours: String(hours), page: String(page) }), {
          timeoutMs: cinemaCatalogPageTimeoutMs,
          maxBytes: cinemaCatalogPageMaxBytes,
          headers: { 'user-agent': rule.userAgent },
        });
        return parseCatalogPage(raw, rule);
      } catch (error) {
        if (attempt >= cinemaCatalogPageAttempts) throw error;
        await new Promise((resolve) => setTimeout(resolve, 2000 * attempt));
      }
    }
  }

  // 写一批；条数到上限就不再加新的（上限是现在上游规模的三倍，碰到时记日志），返回写了几条。
  private async store(ruleId: string, entries: { source: string; folded: string }[], now: Date) {
    if (entries.length === 0) return 0;
    if ((await this.catalog.count(ruleId)) + entries.length > cinemaCatalogEntryLimit) {
      this.logger.warn(`[CinemaCatalog] action=full rule=${ruleId}`);
      return 0;
    }
    for (let start = 0; start < entries.length; start += 500) {
      await this.catalog.upsert(ruleId, entries.slice(start, start + 500), now);
    }
    return entries.length;
  }
}
