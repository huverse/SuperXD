import { mkdir, rm, utimes, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import request from 'supertest';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { appFilePerHour, appReleasePerHour } from 'src/common/relay_limits';

let app: NestExpressApplication;
let server: string;
const dir = () => env().releasesDir;

const apkBytes = Buffer.from(Array.from({ length: 4096 }, (_, index) => index % 251));
const manifest = (overrides: Record<string, unknown> = {}) => ({
  versionCode: 5,
  versionName: '1.0.0-alpha.4',
  publishedAt: '2026-10-16T08:00:00Z',
  minSupportedVersionCode: 0,
  notes: '修了一些问题',
  releasePage: 'https://github.com/huverse/SuperXD/releases/tag/v1.0.0-alpha.4',
  apks: [{ abi: 'arm64-v8a', file: 'SuperXD-1.0.0-alpha.4-arm64-v8a.apk', size: apkBytes.length, sha256: 'a'.repeat(64) }],
  ...overrides,
});

// 每次写入都把修改时间往后挪，服务端按修改时间与大小判断要不要重读，同一秒内连写两次也能认出来。
let stamp = Date.now() / 1000;
const putManifest = async (channel: string, body: unknown) => {
  const path = join(dir(), `${channel}.json`);
  await writeFile(path, typeof body === 'string' ? body : JSON.stringify(body));
  stamp += 10;
  await utimes(path, stamp, stamp);
};

beforeAll(async () => {
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
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

// 限流按小时固定窗口计数：把时钟钉在窗口中段，预置计数与再次请求不会恰好跨过整点。
const pinClock = () => {
  const middle = (Math.floor(Date.now() / 3600_000) + 0.5) * 3600_000;
  vi.spyOn(Date, 'now').mockReturnValue(middle);
};

const fillRate = async (scope: string, limit: number) => {
  const redis = app.get<Redis>(REDIS);
  const prefix = redis.options.keyPrefix ?? '';
  const [, keys] = await redis.scan('0', 'MATCH', `${prefix}${RedisKeys.rate(scope, '*', 0).replace(/:0$/, '')}:*`, 'COUNT', 1000);
  expect(keys).toHaveLength(1);
  await redis.set(keys[0].slice(prefix.length), limit, 'KEEPTTL');
};

describe('版本清单', () => {
  it('没有发布清单时回 RELEASE_NOT_FOUND', async () => {
    const response = await request(server).get('/v1/app/releases/alpha').query({ abi: 'arm64-v8a' });
    expect(response.status).toBe(404);
    expect(response.body.code).toBe('RELEASE_NOT_FOUND');
  });

  it('按架构给出安装包，没有这个架构的包时 apk 为空', async () => {
    await putManifest('alpha', manifest());
    const arm = await request(server).get('/v1/app/releases/alpha').query({ abi: 'arm64-v8a' });
    expect(arm.status).toBe(200);
    expect(arm.body).toEqual({
      versionCode: 5,
      versionName: '1.0.0-alpha.4',
      publishedAt: '2026-10-16T08:00:00Z',
      minSupportedVersionCode: 0,
      notes: '修了一些问题',
      releasePage: 'https://github.com/huverse/SuperXD/releases/tag/v1.0.0-alpha.4',
      apk: { url: '/v1/app/files/SuperXD-1.0.0-alpha.4-arm64-v8a.apk', size: apkBytes.length, sha256: 'a'.repeat(64) },
    });
    const x86 = await request(server).get('/v1/app/releases/alpha').query({ abi: 'x86_64' });
    expect(x86.status).toBe(200);
    expect(x86.body.apk).toBeNull();
  });

  it('换了清单立即生效，渠道之间互不影响', async () => {
    await putManifest('alpha', manifest());
    expect((await request(server).get('/v1/app/releases/alpha').query({ abi: 'arm64-v8a' })).body.versionCode).toBe(5);
    await putManifest('alpha', manifest({ versionCode: 6, versionName: '1.0.0-alpha.5' }));
    expect((await request(server).get('/v1/app/releases/alpha').query({ abi: 'arm64-v8a' })).body.versionCode).toBe(6);
    expect((await request(server).get('/v1/app/releases/beta').query({ abi: 'arm64-v8a' })).status).toBe(404);
  });

  it('架构或渠道不合法回 INVALID_REQUEST', async () => {
    expect((await request(server).get('/v1/app/releases/alpha').query({ abi: 'mips' })).body.code).toBe('INVALID_REQUEST');
    expect((await request(server).get('/v1/app/releases/alpha')).body.code).toBe('INVALID_REQUEST');
    expect((await request(server).get('/v1/app/releases/Alpha%2E%2E').query({ abi: 'arm64-v8a' })).body.code).toBe('INVALID_REQUEST');
  });

  it('清单写坏了不往外发，回 INTERNAL 并打印堆栈', async () => {
    const printed = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    await putManifest('alpha', manifest({ apks: [{ abi: 'arm64-v8a', file: '../secret.apk', size: 1, sha256: 'a'.repeat(64) }] }));
    const response = await request(server).get('/v1/app/releases/alpha').query({ abi: 'arm64-v8a' });
    expect(response.status).toBe(500);
    expect(response.body.code).toBe('INTERNAL');
    expect(printed).toHaveBeenCalled();
    await putManifest('alpha', '{not json');
    expect((await request(server).get('/v1/app/releases/alpha').query({ abi: 'arm64-v8a' })).body.code).toBe('INTERNAL');
  });

  it('同一 IP 每小时超过上限回 RATE_LIMITED', async () => {
    pinClock();
    await putManifest('alpha', manifest());
    await request(server).get('/v1/app/releases/alpha').query({ abi: 'arm64-v8a' });
    await fillRate('app_release', appReleasePerHour);
    const response = await request(server).get('/v1/app/releases/alpha').query({ abi: 'arm64-v8a' });
    expect(response.status).toBe(429);
    expect(response.body.code).toBe('RATE_LIMITED');
    expect(response.body.retryAfter).toBeGreaterThan(0);
  });
});

describe('安装包下载', () => {
  const file = 'SuperXD-1.0.0-alpha.4-arm64-v8a.apk';

  it('整包下载与断点续传', async () => {
    await writeFile(join(dir(), file), apkBytes);
    const whole = await request(server).get(`/v1/app/files/${file}`).buffer(true).parse((response, done) => {
      const chunks: Buffer[] = [];
      response.on('data', (chunk: Buffer) => chunks.push(chunk));
      response.on('end', () => done(null, Buffer.concat(chunks)));
    });
    expect(whole.status).toBe(200);
    expect(whole.headers['content-type']).toBe('application/vnd.android.package-archive');
    expect(whole.headers['accept-ranges']).toBe('bytes');
    expect(Buffer.compare(whole.body as Buffer, apkBytes)).toBe(0);
    const part = await request(server).get(`/v1/app/files/${file}`).set('Range', 'bytes=100-199');
    expect(part.status).toBe(206);
    expect(part.headers['content-range']).toBe(`bytes 100-199/${apkBytes.length}`);
    expect(part.headers['content-length']).toBe('100');
  });

  it('文件不存在回 RELEASE_NOT_FOUND，不是安装包的名字回 INVALID_REQUEST', async () => {
    const missing = await request(server).get(`/v1/app/files/${file}`);
    expect(missing.status).toBe(404);
    expect(missing.body.code).toBe('RELEASE_NOT_FOUND');
    await putManifest('alpha', manifest());
    expect((await request(server).get('/v1/app/files/alpha.json')).body.code).toBe('INVALID_REQUEST');
    expect((await request(server).get('/v1/app/files/.hidden.apk')).body.code).toBe('INVALID_REQUEST');
    expect((await request(server).get('/v1/app/files/..%2Falpha.apk')).body.code).toBe('INVALID_REQUEST');
  });

  it('同一 IP 每小时超过上限回 RATE_LIMITED', async () => {
    pinClock();
    await writeFile(join(dir(), file), apkBytes);
    await request(server).get(`/v1/app/files/${file}`);
    await fillRate('app_file', appFilePerHour);
    const response = await request(server).get(`/v1/app/files/${file}`);
    expect(response.status).toBe(429);
    expect(response.body.code).toBe('RATE_LIMITED');
  });
});
