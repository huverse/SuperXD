import { mkdir, rm, utimes, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import request from 'supertest';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { appFilePerHour, appReleaseFileMaxBytes, appReleasePerHour, developerNotesPerHour } from 'src/common/relay_limits';

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

// 签名信封：中转只校验形状、原样透传，不验签（受信公钥只在客户端），所以这里用合成的字节即可。
const envelope = (tag: string) => ({ signed: Buffer.from(`{"tag":"${tag}"}`).toString('base64url'), signatures: [{ keyId: 'release-2026-11', sig: 'A'.repeat(86) }] });

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
      envelope: null,
    });
    const x86 = await request(server).get('/v1/app/releases/alpha').query({ abi: 'x86_64' });
    expect(x86.status).toBe(200);
    expect(x86.body.apk).toBeNull();
  });

  it('带签名的清单：明文字段照旧给旧客户端，按架构把那一份信封原样透传，没有这个架构的信封时为空', async () => {
    const envelopes = { 'arm64-v8a': envelope('arm'), 'armeabi-v7a': { ...envelope('v7a'), signatures: [{ keyId: 'release-2026-11', sig: 'B'.repeat(86) }, { keyId: 'offline-2026-11', sig: 'C'.repeat(86) }] } };
    await putManifest('alpha', manifest({ envelopes }));
    const arm = await request(server).get('/v1/app/releases/alpha').query({ abi: 'arm64-v8a' });
    expect(arm.status).toBe(200);
    expect(arm.body.versionCode).toBe(5);
    expect(arm.body.apk.url).toBe('/v1/app/files/SuperXD-1.0.0-alpha.4-arm64-v8a.apk');
    expect(arm.body.envelope).toEqual(envelopes['arm64-v8a']);
    expect((await request(server).get('/v1/app/releases/alpha').query({ abi: 'armeabi-v7a' })).body.envelope).toEqual(envelopes['armeabi-v7a']);
    expect((await request(server).get('/v1/app/releases/alpha').query({ abi: 'x86_64' })).body.envelope).toBeNull();
  });

  it('信封写坏了同样不往外发：不是 base64url、没有签名、签名太多或长度不对、多出字段、不认识的架构', async () => {
    const printed = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const good = envelope('arm');
    for (const broken of [
      { 'arm64-v8a': { ...good, signed: 'not base64!' } },
      { 'arm64-v8a': { ...good, signatures: [] } },
      { 'arm64-v8a': { ...good, signatures: Array.from({ length: 5 }, () => good.signatures[0]) } },
      { 'arm64-v8a': { ...good, signatures: [{ keyId: 'release-2026-11', sig: 'A'.repeat(85) }] } },
      { 'arm64-v8a': { ...good, signatures: [{ keyId: 'Bad Id', sig: 'A'.repeat(86) }] } },
      { 'arm64-v8a': { ...good, extra: 1 } },
      { mips: good },
      'x',
    ]) {
      await putManifest('alpha', manifest({ envelopes: broken }));
      const response = await request(server).get('/v1/app/releases/alpha').query({ abi: 'arm64-v8a' });
      expect(response.status).toBe(500);
      expect(response.body.code).toBe('INTERNAL');
    }
    expect(printed).toHaveBeenCalled();
  });

  it('清单文件按 128KB 封顶：三份信封加写满的更新说明放得下，超过就不读', async () => {
    const printed = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const big = { signed: 'A'.repeat(20_000), signatures: [{ keyId: 'release-2026-11', sig: 'A'.repeat(86) }] };
    await putManifest('alpha', manifest({ notes: '字'.repeat(4000), envelopes: { 'arm64-v8a': big, 'armeabi-v7a': big, x86_64: big } }));
    expect((await request(server).get('/v1/app/releases/alpha').query({ abi: 'x86_64' })).body.envelope).toEqual(big);
    await putManifest('alpha', manifest({ envelopes: { 'arm64-v8a': { ...big, signed: 'A'.repeat(appReleaseFileMaxBytes) } } }));
    expect((await request(server).get('/v1/app/releases/alpha').query({ abi: 'arm64-v8a' })).body.code).toBe('INTERNAL');
    expect(printed).toHaveBeenCalled();
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

// 按需下载的字体包（客户端 lib/domain/font_pack.dart）与安装包同目录、同一个下载接口，按扩展名给类型，限流与同时下载上限共用。
describe('字体包下载', () => {
  const font = 'noto_serif_sc_regular-0123456789ab.ttf';
  const fontBytes = Buffer.from(Array.from({ length: 2048 }, (_, index) => (index * 7) % 256));

  it('整个下载与断点续传，类型是 font/ttf', async () => {
    await writeFile(join(dir(), font), fontBytes);
    const whole = await request(server).get(`/v1/app/files/${font}`).buffer(true).parse((response, done) => {
      const chunks: Buffer[] = [];
      response.on('data', (chunk: Buffer) => chunks.push(chunk));
      response.on('end', () => done(null, Buffer.concat(chunks)));
    });
    expect(whole.status).toBe(200);
    expect(whole.headers['content-type']).toBe('font/ttf');
    expect(whole.headers['content-length']).toBe(String(fontBytes.length));
    expect(Buffer.compare(whole.body as Buffer, fontBytes)).toBe(0);
    const part = await request(server).get(`/v1/app/files/${font}`).set('Range', 'bytes=0-9');
    expect(part.status).toBe(206);
    expect(part.headers['content-range']).toBe(`bytes 0-9/${fontBytes.length}`);
  });

  it('不在目录里回 RELEASE_NOT_FOUND，别的扩展名与路径穿越回 INVALID_REQUEST', async () => {
    const missing = await request(server).get(`/v1/app/files/${font}`);
    expect(missing.status).toBe(404);
    expect(missing.body.code).toBe('RELEASE_NOT_FOUND');
    await writeFile(join(dir(), 'font.otf'), fontBytes);
    for (const name of ['font.otf', '.hidden.ttf', '..%2Ffont.ttf', 'font.ttf.json']) {
      expect((await request(server).get(`/v1/app/files/${name}`)).body.code, name).toBe('INVALID_REQUEST');
    }
  });

  it('与安装包共用每小时的下载上限', async () => {
    pinClock();
    await writeFile(join(dir(), font), fontBytes);
    await request(server).get(`/v1/app/files/${font}`);
    await fillRate('app_file', appFilePerHour);
    const response = await request(server).get(`/v1/app/files/${font}`);
    expect(response.status).toBe(429);
    expect(response.body.code).toBe('RATE_LIMITED');
  });
});

describe('开发者的话', () => {
  const note = (id: string, overrides: Record<string, unknown> = {}) => ({ id, title: '近况', publishedAt: '2026-10-24T13:30:00.000Z', body: '第一段\n\n第二段', ...overrides });

  it('还没放清单时给空列表，信封为空', async () => {
    const response = await request(server).get('/v1/app/notes');
    expect(response.status).toBe(200);
    expect(response.body).toEqual({ notes: [], envelope: null });
  });

  it('原样给出清单里的信，换了文件立即生效', async () => {
    await putManifest('developer_notes', { notes: [note('2026-10-24-hello')] });
    expect((await request(server).get('/v1/app/notes')).body).toEqual({ notes: [note('2026-10-24-hello')], envelope: null });
    await putManifest('developer_notes', { notes: [note('2026-10-25-again', { title: '又来了' }), note('2026-10-24-hello')] });
    expect((await request(server).get('/v1/app/notes')).body.notes.map((item: { id: string }) => item.id)).toEqual(['2026-10-25-again', '2026-10-24-hello']);
  });

  it('签好的清单：明文 notes 照旧给旧客户端，信封原样透传', async () => {
    const file = { notes: [note('2026-10-24-hello')], envelope: { ...envelope('notes'), signatures: [{ keyId: 'notes-2026-11', sig: 'D'.repeat(86) }] } };
    await putManifest('developer_notes', file);
    expect((await request(server).get('/v1/app/notes')).body).toEqual(file);
    // 签好的空列表（还没写过信时流水线也会上传）同样原样透传。
    await putManifest('developer_notes', { notes: [], envelope: envelope('empty') });
    expect((await request(server).get('/v1/app/notes')).body).toEqual({ notes: [], envelope: envelope('empty') });
  });

  it('清单写坏了不往外发，回 INTERNAL 并打印堆栈', async () => {
    const printed = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    for (const body of [
      { notes: [note('../escape')] },
      { notes: [note('long', { body: '字'.repeat(4001) })] },
      { notes: Array.from({ length: 31 }, (_, index) => note(`n${index}`)) },
      { notes: [note('extra', { secret: 1 })] },
      { notes: [], envelope: { ...envelope('x'), signed: '' } },
      { notes: [], envelope: { ...envelope('x'), signatures: [{ keyId: 'notes-2026-11', sig: 'short' }] } },
      { notes: [], envelope: 'x' },
      '{not json',
    ]) {
      await putManifest('developer_notes', body);
      const response = await request(server).get('/v1/app/notes');
      expect(response.status).toBe(500);
      expect(response.body.code).toBe('INTERNAL');
    }
    expect(printed).toHaveBeenCalled();
  });

  it('同一 IP 每小时超过上限回 RATE_LIMITED', async () => {
    pinClock();
    await request(server).get('/v1/app/notes');
    await fillRate('developer_notes', developerNotesPerHour);
    const response = await request(server).get('/v1/app/notes');
    expect(response.status).toBe(429);
    expect(response.body.code).toBe('RATE_LIMITED');
  });
});
