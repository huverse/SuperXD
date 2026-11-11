import { randomBytes } from 'node:crypto';
import { mkdir, readdir, readFile, rm, stat, utimes, writeFile } from 'node:fs/promises';
import { request as httpRequest } from 'node:http';
import { join } from 'node:path';
import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import request from 'supertest';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { diagnosticKeepDays, diagnosticStoreMaxBytes, diagnosticStoreMaxFiles, diagnosticUploadMaxBytes, diagnosticUploadPerHour } from 'src/common/relay_limits';
import { DiagnosticRetentionTask } from 'src/modules/diagnostic/diagnostic_retention.task';

let app: NestExpressApplication;
let server: string;
const dir = () => env().diagnosticsDir;
const redis = () => app.get<Redis>(REDIS);

beforeAll(async () => {
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
});

// 用例都从 127.0.0.1 发请求：每个用例前清空限流计数、已用量与目录，互不影响。
beforeEach(async () => {
  await redis().flushdb();
  await rm(dir(), { recursive: true, force: true });
  await mkdir(dir(), { recursive: true });
});

afterEach(() => {
  vi.restoreAllMocks();
});

afterAll(async () => {
  await app.close();
  await rm(dir(), { recursive: true, force: true });
});

const upload = (body: Buffer) => request(server).post('/v1/diagnostics').set('Content-Type', 'application/octet-stream').send(body);
const usage = async () => redis().hgetall(RedisKeys.diagnosticUsage());

// 直接用 node 的 http 发：可以只声明长度不发完、或不带长度分块发，看服务端在读请求体之前怎么回。
const rawPost = (headers: Record<string, string | number>, chunks: Buffer[], options: { end: boolean }) =>
  new Promise<{ status: number; body: string }>((resolve, reject) => {
    const url = new URL('/v1/diagnostics', server);
    const outgoing = httpRequest({ hostname: url.hostname, port: url.port, path: url.pathname, method: 'POST', headers }, (response) => {
      const parts: Buffer[] = [];
      response.on('data', (part: Buffer) => parts.push(part));
      response.on('end', () => {
        resolve({ status: response.statusCode ?? 0, body: Buffer.concat(parts).toString() });
        outgoing.destroy();
      });
    });
    outgoing.on('error', reject);
    for (const chunk of chunks) outgoing.write(chunk);
    if (options.end) outgoing.end();
  });

// 等服务端处理完一个被客户端掐断的请求（写盘出错、清理残片、退回预占都在请求之后异步发生）。
const eventually = async (check: () => Promise<boolean>) => {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  expect(await check()).toBe(true);
};

// 限流按小时固定窗口计数：把时钟钉在窗口中段，预置计数与再次请求不会恰好跨过整点。
const pinClock = () => {
  const middle = (Math.floor(Date.now() / 3600_000) + 0.5) * 3600_000;
  vi.spyOn(Date, 'now').mockReturnValue(middle);
};

describe('诊断包', () => {
  it('密文原样存成以诊断编号命名的文件（只给服务进程读写），回编号与保留天数，并记进已用量；没有下载接口', async () => {
    const body = randomBytes(4096);
    const response = await upload(body).expect(200);
    expect(response.body).toEqual({ id: expect.stringMatching(/^[0-9A-HJKMNP-TV-Z]{8}$/), keepDays: diagnosticKeepDays });
    const path = join(dir(), response.body.id);
    expect(await readFile(path)).toEqual(body);
    expect((await stat(path)).mode & 0o777).toBe(0o600);
    expect(await readdir(dir())).toEqual([response.body.id]);
    expect(await usage()).toEqual({ bytes: '4096', files: '1' });

    const second = await upload(randomBytes(100)).expect(200);
    expect(second.body.id).not.toBe(response.body.id);
    expect(await usage()).toEqual({ bytes: '4196', files: '2' });

    await request(server).get('/v1/diagnostics').expect(404);
    await request(server).get(`/v1/diagnostics/${response.body.id}`).expect(404);
  });

  it('只收二进制请求体；不到一个信封头的回 400，都不落盘', async () => {
    const json = await request(server).post('/v1/diagnostics').send({ data: 'x' });
    expect(json.status).toBe(415);
    expect(json.body.code).toBe('INVALID_REQUEST');
    const tiny = await upload(randomBytes(60));
    expect(tiny.status).toBe(400);
    expect(tiny.body.code).toBe('INVALID_REQUEST');
    await upload(Buffer.alloc(0)).expect(400);
    expect(await readdir(dir())).toEqual([]);
    expect(await usage()).toEqual({});
  });

  it('声明长度超过 24MB 的在读请求体之前就回 413，没声明长度的分块上传同样拒收', async () => {
    const huge = await rawPost({ 'Content-Type': 'application/octet-stream', 'Content-Length': diagnosticUploadMaxBytes + 1 }, [randomBytes(16)], { end: false });
    expect(huge.status).toBe(413);
    expect(JSON.parse(huge.body).code).toBe('ENVELOPE_TOO_LARGE');
    const chunked = await rawPost({ 'Content-Type': 'application/octet-stream', 'Transfer-Encoding': 'chunked' }, [randomBytes(128)], { end: true });
    expect(chunked.status).toBe(413);
    expect(await readdir(dir())).toEqual([]);
  });

  it('同一来源每小时超过上限回 429', async () => {
    pinClock();
    await upload(randomBytes(100)).expect(200);
    const prefix = redis().options.keyPrefix ?? '';
    const [, keys] = await redis().scan('0', 'MATCH', `${prefix}${RedisKeys.rate('diagnostic_upload', '*', 0).replace(/:0$/, '')}:*`, 'COUNT', 1000);
    expect(keys).toHaveLength(1);
    await redis().set(keys[0].slice(prefix.length), diagnosticUploadPerHour, 'KEEPTTL');
    const limited = await upload(randomBytes(100));
    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
    expect(await readdir(dir())).toHaveLength(1);
  });

  it('目录总量或个数到上限时回 503，不落盘也不占额度', async () => {
    await redis().hset(RedisKeys.diagnosticUsage(), { bytes: diagnosticStoreMaxBytes - 100, files: 0 });
    await upload(randomBytes(100)).expect(200);
    const full = await upload(randomBytes(100));
    expect(full.status).toBe(503);
    expect(full.body.code).toBe('MAILBOX_FULL');
    expect(await usage()).toEqual({ bytes: String(diagnosticStoreMaxBytes), files: '1' });

    await redis().hset(RedisKeys.diagnosticUsage(), { bytes: 0, files: diagnosticStoreMaxFiles });
    await upload(randomBytes(100)).expect(503);
    expect(await readdir(dir())).toHaveLength(1);
  });

  it('客户端传到一半断开：不留残片，预占的额度退回', async () => {
    await upload(randomBytes(200)).expect(200);
    const url = new URL('/v1/diagnostics', server);
    const outgoing = httpRequest({ hostname: url.hostname, port: url.port, path: url.pathname, method: 'POST', headers: { 'Content-Type': 'application/octet-stream', 'Content-Length': 100_000 } });
    outgoing.on('error', () => {});
    outgoing.write(randomBytes(1000));
    // 等服务端预占好、开始写残片，再掐断。
    await eventually(async () => (await readdir(dir())).some((name) => name.endsWith('.part')));
    expect(await usage()).toEqual({ bytes: '100200', files: '2' });
    outgoing.destroy();
    await eventually(async () => (await usage()).bytes === '200');
    expect(await usage()).toEqual({ bytes: '200', files: '1' });
    await eventually(async () => (await readdir(dir())).length === 1);
  });

  it('清理任务删掉满 30 天的包与一小时前断掉的残片，新的留下，已用量按目录实际重写', async () => {
    const fresh = (await upload(randomBytes(300)).expect(200)).body.id as string;
    const old = (await upload(randomBytes(500)).expect(200)).body.id as string;
    const backdate = async (name: string, ms: number) => {
      const seconds = (Date.now() - ms) / 1000;
      await utimes(join(dir(), name), seconds, seconds);
    };
    await backdate(old, diagnosticKeepDays * 86400_000 + 60_000);
    await writeFile(join(dir(), 'ABCDEFGH.part'), randomBytes(50));
    await backdate('ABCDEFGH.part', 2 * 3600_000);
    await writeFile(join(dir(), 'JKMNPQRS.part'), randomBytes(70));
    // 不认识的文件不碰也不计。
    await writeFile(join(dir(), 'README.txt'), 'x');
    // Redis 里的数和目录对不上（如 Redis 丢过），清理时按目录校正。
    await redis().hset(RedisKeys.diagnosticUsage(), { bytes: 999_999, files: 99 });

    await app.get(DiagnosticRetentionTask).sweep();
    expect((await readdir(dir())).sort()).toEqual([fresh, 'JKMNPQRS.part', 'README.txt'].sort());
    expect(await usage()).toEqual({ bytes: '370', files: '2' });
    expect(await redis().ttl(RedisKeys.diagnosticUsage())).toBeGreaterThan(0);
  });
});
