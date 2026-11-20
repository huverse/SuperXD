import { readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { Injectable, Logger } from '@nestjs/common';

import { env } from 'src/config/env';
import { cinemaFileMaxBytes } from 'src/common/relay_limits';

// 片名目录型源的抓取配置：从发布目录的 cinema.json（维护者本机签好上传的片源规则包，见客户端 tool/cinema_publish.sh）里读 catalogRules，
// 规则不进公开仓库、也不在中转另配一份。信封里的载荷是规则包原文（签名只给手机验，中转信得过自己的发布目录），按修改时间与大小缓存，换文件即生效。
// 规则的写法同客户端 lib/toolbox/cinema/cinema_rule.dart 的 CinemaCatalogConfig：update 请求带 @hours、@page，listPath、idPath、namePath、pageCountPath 是限定写法的 JSONPath。
export type CinemaCatalogRule = {
  id: string;
  userAgent: string;
  url: string;
  query: Record<string, string>;
  listPath: string;
  idPath: string;
  namePath: string;
  pageCountPath: string;
};

const ruleIdPattern = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const jsonPathPattern = /^\$((\.[A-Za-z0-9_$-]+)|(\[(\d+|\*|'[^']*'|"[^"]*")\]))*$/;
const defaultUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

@Injectable()
export class CinemaCatalogSource {
  private readonly logger = new Logger('CinemaCatalogSource');
  private cache: { mtimeMs: number; size: number; rules: CinemaCatalogRule[] } | undefined;

  // 还没放规则包时为空；规则包写坏了抛错（交给调用方记日志），不拿半份去抓。
  async rules(): Promise<CinemaCatalogRule[]> {
    const path = join(env().releasesDir, 'cinema.json');
    let info: Awaited<ReturnType<typeof stat>>;
    try {
      info = await stat(path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      this.cache = undefined;
      return [];
    }
    const cached = this.cache;
    if (cached !== undefined && cached.mtimeMs === info.mtimeMs && cached.size === info.size) return cached.rules;
    if (info.size > cinemaFileMaxBytes) throw new Error(`cinema.json 超过 ${cinemaFileMaxBytes} 字节`);
    const file = JSON.parse(await readFile(path, 'utf8')) as { envelope?: { signed?: unknown } | null };
    const signed = file.envelope?.signed;
    const rules = typeof signed === 'string' ? decodeCatalogRules(JSON.parse(Buffer.from(signed, 'base64url').toString('utf8'))) : [];
    this.cache = { mtimeMs: info.mtimeMs, size: info.size, rules };
    this.logger.log(`[CinemaCatalogSource] action=load rules=${rules.length}`);
    return rules;
  }
}

// 规则包里的 catalogRules：逐项核对外形，不合格整份不用（同客户端「不合格整包不用」）。
export const decodeCatalogRules = (pkg: unknown): CinemaCatalogRule[] => {
  const raw = (pkg as { catalogRules?: unknown } | null)?.catalogRules ?? [];
  if (!Array.isArray(raw)) throw new Error('catalogRules 要是数组');
  return raw.map((item, index) => {
    const rule = item as { id?: unknown; userAgent?: unknown; catalog?: { update?: Record<string, unknown> } };
    const update = rule.catalog?.update;
    const request = update?.request as { method?: unknown; url?: unknown; query?: unknown } | undefined;
    const paths = ['listPath', 'idPath', 'namePath', 'pageCountPath'].map((key) => update?.[key]);
    const query = request?.query ?? {};
    const valid =
      typeof rule.id === 'string' &&
      ruleIdPattern.test(rule.id) &&
      typeof request?.url === 'string' &&
      /^https?:\/\/[^/@]+/.test(request.url) &&
      (request.method ?? 'GET') === 'GET' &&
      typeof query === 'object' &&
      Object.values(query as object).every((value) => typeof value === 'string') &&
      paths.every((path) => typeof path === 'string' && jsonPathPattern.test(path));
    if (!valid) throw new Error(`catalogRules[${index}] 写法不对`);
    const [listPath, idPath, namePath, pageCountPath] = paths as string[];
    return {
      id: rule.id as string,
      userAgent: typeof rule.userAgent === 'string' && rule.userAgent !== '' ? rule.userAgent : defaultUserAgent,
      url: request!.url as string,
      query: query as Record<string, string>,
      listPath,
      idPath,
      namePath,
      pageCountPath,
    };
  });
};

// 填 @变量：url 里按 URL 编码，query 合进地址（同客户端 prepareCinemaRequest）。
export const catalogPageUrl = (rule: CinemaCatalogRule, variables: Record<string, string>) => {
  const fill = (text: string, encode: boolean) => text.replace(/@([A-Za-z_][A-Za-z0-9_]*)/g, (match, name: string) => (name in variables ? (encode ? encodeURIComponent(variables[name]) : variables[name]) : match));
  const url = new URL(fill(rule.url, true));
  for (const [key, value] of Object.entries(rule.query)) url.searchParams.set(key, fill(value, false));
  return url.toString();
};

// 限定写法的 JSONPath（同客户端 validateCinemaJsonPath）：$ 开头，后面是 .名字、[数字]、[*]、['名字']。
export const readPath = (document: unknown, expression: string): unknown[] => {
  if (!jsonPathPattern.test(expression)) throw new Error(`不支持的 JSONPath：${expression}`);
  let nodes: unknown[] = [document];
  for (const step of expression.slice(1).match(/\.[A-Za-z0-9_$-]+|\[(?:\d+|\*|'[^']*'|"[^"]*")\]/g) ?? []) {
    const next: unknown[] = [];
    for (const node of nodes) {
      if (step === '[*]') {
        if (Array.isArray(node)) next.push(...(node as unknown[]));
        else if (node !== null && typeof node === 'object') next.push(...Object.values(node));
        continue;
      }
      const key = step.startsWith('.') ? step.slice(1) : step.slice(1, -1).replace(/^['"]|['"]$/g, '');
      if (Array.isArray(node)) {
        if (/^\d+$/.test(key) && Number(key) < node.length) next.push(node[Number(key)]);
      } else if (node !== null && typeof node === 'object' && Object.hasOwn(node, key)) {
        next.push((node as Record<string, unknown>)[key]);
      }
    }
    nodes = next;
  }
  return nodes;
};

const firstText = (node: unknown, expression: string) => {
  const value = readPath(node, expression)[0];
  return typeof value === 'string' ? value.trim() : typeof value === 'number' ? String(value) : '';
};

// 一页：每条的编号与片名折叠写法，与总页数（取不到当 1）。片名太长的截到 255 个字。
export const parseCatalogPage = (raw: string, rule: CinemaCatalogRule) => {
  const document = JSON.parse(raw) as unknown;
  const entries: { source: string; folded: string }[] = [];
  for (const node of readPath(document, rule.listPath)) {
    const source = firstText(node, rule.idPath), folded = cinemaFold(firstText(node, rule.namePath)).slice(0, 255);
    if (source !== '' && source.length <= 64 && folded !== '') entries.push({ source, folded });
  }
  return { entries, pageCount: Number.parseInt(firstText(document, rule.pageCountPath), 10) || 1 };
};

// 片名的折叠写法（同客户端 cinemaFold）：去空白、全角折半角、小写；入库与查询都按它。
export const cinemaFold = (name: string) => {
  let folded = '';
  for (const char of name) {
    const code = char.codePointAt(0)!;
    const mapped = String.fromCodePoint(code === 0x3000 ? 0x20 : code >= 0xff01 && code <= 0xff5e ? code - 0xfee0 : code);
    if (mapped.trim() !== '') folded += mapped.toLowerCase();
  }
  return folded;
};
