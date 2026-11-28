import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { createServer, Server } from 'node:http';
import { AddressInfo } from 'node:net';
import { mkdir, rm, utimes, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import request from 'supertest';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { cinemaCatalogEntryLimit, cinemaCatalogSearchPerHour } from 'src/common/relay_limits';
import { CinemaCatalogRepository } from 'src/modules/cinema_catalog/cinema_catalog.repository';
import { CinemaCatalogService } from 'src/modules/cinema_catalog/cinema_catalog.service';
import { catalogPageUrl, cinemaFold, decodeCatalogRules, parseCatalogPage, readPath } from 'src/modules/cinema_catalog/cinema_catalog_source';

// 电影院片名目录型源的服务端索引（人工决策见 src/modules/cinema_catalog/cinema_catalog.service.ts）：
// 配置读发布目录的 cinema.json，抓全可断点续抓、之后补增量，搜索按 ngram 全文索引（一个字退回 LIKE），搜索词不进地址。
let app: NestExpressApplication;
let server: string;
let database: DataSource;
let upstream: Server;
let upstreamUrl: string;
let stamp = Date.now() / 1000;
const requests: URLSearchParams[] = [];
let failPage: number | null = null;
let busyPage: number | null = null;
let pages: { vod_id: number | string; vod_name: string }[][] = [];

const cinemaFile = () => join(env().releasesDir, 'cinema.json');

const writeRules = async (catalogRules: unknown[]) => {
  const payload = Buffer.from(JSON.stringify({ format: 1, version: 1, rules: [], catalogRules })).toString('base64url');
  await writeFile(cinemaFile(), JSON.stringify({ version: 1, envelope: { signed: payload, signatures: [{ keyId: 'notes-2026-11', sig: 'A'.repeat(86) }] } }));
  stamp += 10;
  await utimes(cinemaFile(), stamp, stamp);
};

const wsyRule = () => ({
  id: 'wsy',
  name: '目录资源',
  userAgent: '',
  catalog: {
    update: {
      request: { method: 'GET', url: `${upstreamUrl}/api.php/provide/vod/`, query: { ac: 'list', h: '@hours', pg: '@page' } },
      listPath: '$.list[*]',
      idPath: '$.vod_id',
      namePath: '$.vod_name',
      pageCountPath: '$.pagecount',
    },
  },
});

const search = (q: string, id = 'wsy') => request(server).post(`/v1/app/cinema/catalogs/${id}/search`).send({ q });

beforeAll(async () => {
  await mkdir(env().releasesDir, { recursive: true });
  upstream = createServer((incoming, response) => {
    const query = new URL(incoming.url ?? '/', 'http://x').searchParams;
    requests.push(query);
    const page = Number(query.get('pg'));
    if (page === failPage) {
      response.writeHead(502).end();
      return;
    }
    if (page === busyPage) {
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      response.end(JSON.stringify({ code: 1, msg: '服务器繁忙，请稍后搜索' }));
      return;
    }
    response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    response.end(JSON.stringify({ code: 1, page, pagecount: pages.length, list: pages[page - 1] ?? [] }));
  });
  await new Promise<void>((resolve) => upstream.listen(0, '127.0.0.1', resolve));
  upstreamUrl = `http://127.0.0.1:${(upstream.address() as AddressInfo).port}`;
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  database = app.get(DataSource);
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
  await database.query('DELETE FROM cinema_catalog');
  await database.query('DELETE FROM cinema_catalog_state');
  requests.length = 0;
  failPage = null;
  busyPage = null;
  pages = [
    [
      { vod_id: 101, vod_name: '庆余年 第二季' },
      { vod_id: 102, vod_name: '庆余年' },
    ],
    [
      { vod_id: 103, vod_name: 'ＴＨＥ Ｂｏｙｓ' },
      { vod_id: 104, vod_name: '余生' },
    ],
    [{ vod_id: 105, vod_name: '庆余年之帝王业' }],
  ];
  await writeRules([wsyRule()]);
});

afterAll(async () => {
  await rm(cinemaFile(), { force: true });
  await app.close();
  await new Promise((resolve) => upstream.close(resolve));
});

describe('片名目录', () => {
  it('第一次抓全（@hours 填大数、逐页取完），搜索完全一样的在前、开头一样的其次、短的在前；英文与全角按折叠写法认；一个字只找片名开头的', async () => {
    const now = new Date('2026-11-20T08:00:00Z');
    await app.get(CinemaCatalogService).sync(now);
    expect(requests.map((query) => [query.get('h'), query.get('pg')])).toEqual([
      ['200000', '1'],
      ['200000', '2'],
      ['200000', '3'],
    ]);
    const [state] = (await database.query('SELECT crawl_started AS crawlStarted, synced_at AS syncedAt FROM cinema_catalog_state WHERE rule_id = ?', ['wsy'])) as { crawlStarted: Date | null; syncedAt: Date }[];
    expect(state.crawlStarted).toBeNull();
    expect(new Date(state.syncedAt).toISOString()).toBe(now.toISOString());
    const found = await search('庆余年');
    expect(found.status).toBe(200);
    expect(found.body.ids).toEqual(['102', '101', '105']);
    expect((await search(' the boys ')).body.ids).toEqual(['103']);
    expect((await search('余')).body.ids).toEqual(['104']);
    expect((await search('生')).body.ids, '单字不找片名中间的').toEqual([]);
    expect((await search('没有这部')).body.ids).toEqual([]);
  });

  it('之后每轮按离上次多少小时补；抓全中途源连不上就停，下一轮从抓到的页接着抓', async () => {
    const service = app.get(CinemaCatalogService);
    failPage = 2;
    const started = new Date('2026-11-20T08:00:00Z');
    await service.sync(started);
    const [half] = (await database.query('SELECT crawl_page AS crawlPage, synced_at AS syncedAt FROM cinema_catalog_state WHERE rule_id = ?', ['wsy'])) as { crawlPage: number; syncedAt: Date | null }[];
    expect(half.syncedAt).toBeNull();
    expect(half.crawlPage).toBe(1);
    expect((await search('庆余年')).body.ids, '抓到的部分已经能搜').toEqual(['102', '101']);
    failPage = null;
    requests.length = 0;
    await service.sync(new Date('2026-11-20T09:00:00Z'));
    expect(requests.map((query) => query.get('pg'))).toEqual(['2', '3']);
    const [done] = (await database.query('SELECT synced_at AS syncedAt FROM cinema_catalog_state WHERE rule_id = ?', ['wsy'])) as { syncedAt: Date }[];
    expect(new Date(done.syncedAt).toISOString(), '补到的时刻记成抓全的起点').toBe(started.toISOString());
    pages = [[{ vod_id: 106, vod_name: '庆余年 番外' }]];
    requests.length = 0;
    await service.sync(new Date('2026-11-20T11:30:00Z'));
    expect(requests.map((query) => [query.get('h'), query.get('pg')])).toEqual([['5', '1']]);
    expect((await search('庆余年番外')).body.ids).toEqual(['106']);
  });

  // 11-28 Codex 审查 F09：原来目录到了条数上限就整批跳过，已有影片改名也丢、同步照样往前。条数按上限算（不真插 40 万条）。
  it('目录到条数上限：已有的编号照常改名，新编号写不进、记日志，同步照常往前', async () => {
    const service = app.get(CinemaCatalogService);
    await service.sync(new Date('2026-11-20T08:00:00Z'));
    const counting = vi.spyOn(app.get(CinemaCatalogRepository), 'count').mockResolvedValue(cinemaCatalogEntryLimit);
    try {
      pages = [[{ vod_id: 102, vod_name: '庆余年 第一季' }, { vod_id: 107, vod_name: '新上的片' }]];
      await service.sync(new Date('2026-11-20T10:00:00Z'));
      expect((await search('庆余年第一季')).body.ids).toEqual(['102']);
      expect((await search('新上的片')).body.ids).toEqual([]);
      const [state] = (await database.query('SELECT synced_at AS syncedAt FROM cinema_catalog_state WHERE rule_id = ?', ['wsy'])) as { syncedAt: Date }[];
      expect(new Date(state.syncedAt).toISOString()).toBe('2026-11-20T10:00:00.000Z');
    } finally {
      counting.mockRestore();
    }
  });

  it('抓全一轮按时间预算跑：到点停在批与批之间、记下抓到第几页，下一轮接着抓到完', async () => {
    const service = app.get(CinemaCatalogService);
    await service.sync(new Date('2026-11-20T08:00:00Z'), 0);
    expect(requests.map((query) => query.get('pg'))).toEqual(['1']);
    const [half] = (await database.query('SELECT crawl_page AS crawlPage, synced_at AS syncedAt FROM cinema_catalog_state WHERE rule_id = ?', ['wsy'])) as { crawlPage: number; syncedAt: Date | null }[];
    expect(half.syncedAt).toBeNull();
    expect(half.crawlPage).toBe(1);
    requests.length = 0;
    await service.sync(new Date('2026-11-20T09:00:00Z'));
    expect(requests.map((query) => query.get('pg'))).toEqual(['2', '3']);
  });

  // 11-22 Codex 复核：原来增量最多取 50 页、之后照样把同步时刻推到现在，超出的那些永远漏掉（用户选「分轮补完」，人工决策见服务文件头）。
  it('增量一轮取不完：记下取到第几页、同步时刻不推进，下一轮按原来的时间窗接着取，取完才推进到这一串开始的时刻', async () => {
    const service = app.get(CinemaCatalogService);
    const started = new Date('2026-11-20T08:00:00Z');
    await service.sync(started);
    pages = [[{ vod_id: 201, vod_name: '新片甲' }], [{ vod_id: 202, vod_name: '新片乙' }], [{ vod_id: 203, vod_name: '新片丙' }]];
    requests.length = 0;
    const behind = new Date('2026-11-20T10:00:00Z');
    await service.sync(behind, 0);
    expect(requests.map((query) => [query.get('h'), query.get('pg')])).toEqual([['3', '1']]);
    const [half] = (await database.query('SELECT crawl_page AS crawlPage, synced_at AS syncedAt FROM cinema_catalog_state WHERE rule_id = ?', ['wsy'])) as { crawlPage: number; syncedAt: Date }[];
    expect(half.crawlPage).toBe(1);
    expect(new Date(half.syncedAt).toISOString(), '没取完不推进').toBe(started.toISOString());
    requests.length = 0;
    await service.sync(new Date('2026-11-20T11:00:00Z'));
    expect(requests.map((query) => [query.get('h'), query.get('pg')]), '时间窗从原来的同步时刻算，接着第 2 页取').toEqual([
      ['4', '2'],
      ['4', '3'],
    ]);
    const [done] = (await database.query('SELECT crawl_started AS crawlStarted, synced_at AS syncedAt FROM cinema_catalog_state WHERE rule_id = ?', ['wsy'])) as { crawlStarted: Date | null; syncedAt: Date }[];
    expect(done.crawlStarted).toBeNull();
    expect(new Date(done.syncedAt).toISOString(), '推进到这一串开始的时刻').toBe(behind.toISOString());
    expect((await search('新片丙')).body.ids).toEqual(['203']);
  });

  // 11-22 Codex 复核：HTTP 200 的「服务器繁忙」原来当成空页，抓全第一页碰上就记成抓完（页数取不到当 1），中间页碰上那一页永远漏掉。
  it('一页回「服务器繁忙」（没有结果列表）算没取到：不记成抓完、不推进，下一轮从这一页接着取；空列表照旧是真没有', async () => {
    const service = app.get(CinemaCatalogService);
    busyPage = 2;
    const started = new Date('2026-11-20T08:00:00Z');
    await service.sync(started);
    const [half] = (await database.query('SELECT crawl_page AS crawlPage, synced_at AS syncedAt FROM cinema_catalog_state WHERE rule_id = ?', ['wsy'])) as { crawlPage: number; syncedAt: Date | null }[];
    expect(half.syncedAt, '没记成抓完').toBeNull();
    expect(half.crawlPage).toBe(1);
    busyPage = null;
    requests.length = 0;
    await service.sync(new Date('2026-11-20T09:00:00Z'));
    expect(requests.map((query) => query.get('pg'))).toEqual(['2', '3']);
    expect((await search('余生')).body.ids, '繁忙的那一页补上了').toEqual(['104']);
    const rule = decodeCatalogRules({ catalogRules: [wsyRule()] })[0];
    expect(parseCatalogPage(JSON.stringify({ code: 1, pagecount: 1, list: [] }), rule).entries).toEqual([]);
    expect(parseCatalogPage(JSON.stringify({ code: 1, pagecount: 1, list: null }), rule).entries).toEqual([]);
    expect(() => parseCatalogPage(JSON.stringify({ code: 1, msg: '服务器繁忙，请稍后搜索' }), rule)).toThrow('回复里没有结果列表');
  });

  it('规则包里没有的源回 CATALOG_NOT_FOUND，拿掉的源连目录一起删；搜索词要 1 到 80 个字；每个出口每小时有上限', async () => {
    const service = app.get(CinemaCatalogService);
    await service.sync(new Date('2026-11-20T08:00:00Z'));
    expect((await search('庆余年', 'other')).body.code).toBe('CATALOG_NOT_FOUND');
    expect((await search('')).status).toBe(400);
    expect((await search('长'.repeat(81))).status).toBe(400);
    await writeRules([]);
    await service.sync(new Date('2026-11-20T09:00:00Z'));
    expect(Number(((await database.query('SELECT COUNT(*) AS count FROM cinema_catalog')) as { count: string }[])[0].count)).toBe(0);
    await writeRules([wsyRule()]);
    // 搜索词不落库、不进 Redis（限流键只有出口与窗口）。
    const redis = app.get<Redis>(REDIS);
    const keys: string[] = [];
    let cursor = '0';
    do {
      const [next, batch] = await redis.scan(cursor, 'COUNT', 1000);
      keys.push(...batch);
      cursor = next;
    } while (cursor !== '0');
    expect(keys.some((key) => key.includes('庆余'))).toBe(false);
    for (let index = 0; index < cinemaCatalogSearchPerHour; index++) await search('庆余年');
    const limited = await search('庆余年');
    expect(limited.status).toBe(429);
  });

  it('规则包外形不对整份不用；限定写法的 JSONPath；@变量填进地址；折叠写法同客户端', () => {
    expect(() => decodeCatalogRules({ catalogRules: [{ ...wsyRule(), id: 'Bad Id' }] })).toThrow();
    expect(() => decodeCatalogRules({ catalogRules: [{ ...wsyRule(), catalog: { update: { ...wsyRule().catalog.update, listPath: '$.list[?(@.x)]' } } }] })).toThrow();
    const [rule] = decodeCatalogRules({ catalogRules: [wsyRule()] });
    expect(new URL(catalogPageUrl(rule, { hours: '3', page: '2' })).searchParams.toString()).toBe('ac=list&h=3&pg=2');
    expect(readPath({ list: [{ vod_id: 1 }, { vod_id: 2 }] }, '$.list[*].vod_id')).toEqual([1, 2]);
    expect(readPath({ list: [{ a: 1 }] }, "$['list'][0].a")).toEqual([1]);
    expect(cinemaFold('　ＴＨＥ  Boys\t')).toBe('theboys');
  });
});
