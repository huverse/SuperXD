import { randomBytes } from 'node:crypto';
import { mkdir, readdir, readFile, rm, stat, utimes, writeFile } from 'node:fs/promises';
import { request as httpRequest } from 'node:http';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import request from 'supertest';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { DistributedLock, REDIS } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { diagnosticKeepDays, diagnosticStoreMaxBytes, diagnosticStoreMaxFiles, diagnosticUploadMaxBytes, diagnosticUploadPerHour } from 'src/common/relay_limits';
import { DiagnosticReservationLost, DiagnosticStore } from 'src/modules/diagnostic/diagnostic.store';
import { DiagnosticRetentionTask } from 'src/modules/diagnostic/diagnostic_retention.task';
import { insertAccount } from './account_fixture';
import { TestDevice } from './test_device';

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
// 在途预占（「凭据:字节数」），11-28 起与已存好的用量分开记。
const reservations = async () => (await redis().zrange(RedisKeys.diagnosticReservations(), 0, -1)).map((member) => Number(member.split(':')[1]));

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
    expect(response.body).toEqual({ id: expect.stringMatching(/^[0-9A-HJKMNP-TV-Z]{8}$/), keepDays: diagnosticKeepDays, claim: expect.stringMatching(/^[A-Za-z0-9_-]{22}$/) });
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
    expect(await usage()).toEqual({ bytes: '200', files: '1' });
    expect(await reservations()).toEqual([100_000]);
    outgoing.destroy();
    await eventually(async () => (await reservations()).length === 0);
    expect(await usage()).toEqual({ bytes: '200', files: '1' });
    await eventually(async () => (await readdir(dir())).length === 1);
  });

  it('清理任务删掉满 30 天的包与一小时前断掉的残片，新的留下，已用量按目录里存好的包重写（残片的额度在在途预占里）', async () => {
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
    expect(await usage()).toEqual({ bytes: '300', files: '1' });
    expect(await redis().ttl(RedisKeys.diagnosticUsage())).toBeGreaterThan(0);
  });

  // 11-28 Codex 审查 F06：原来清理任务按目录重写已用量，冲掉还没写完的上传的预占，之后退回又把已用量减成少算。
  it('清理任务不碰在途预占：预占 → 清理 → 存好，预占 → 清理 → 退回，已用量与预占都对得上', async () => {
    const store = app.get(DiagnosticStore);
    const kept = (await upload(randomBytes(300)).expect(200)).body.id as string;
    const pending = (await store.reserve(1000))!;
    await app.get(DiagnosticRetentionTask).sweep();
    expect(await usage()).toEqual({ bytes: '300', files: '1' });
    expect(await reservations()).toEqual([1000]);
    await store.save('ABCDEFGJ', Readable.from([randomBytes(1000)]), pending);
    expect(await usage()).toEqual({ bytes: '1300', files: '2' });
    expect(await reservations()).toEqual([]);

    const abandoned = (await store.reserve(2000))!;
    await app.get(DiagnosticRetentionTask).sweep();
    await store.release(abandoned);
    // 退回不动已存好的用量、不会减成负数。
    expect(await usage()).toEqual({ bytes: '1300', files: '2' });
    expect(await reservations()).toEqual([]);
    expect((await readdir(dir())).sort()).toEqual(['ABCDEFGJ', kept].sort());
  });

  it('在途预占也算进上限；过了 10 分钟还没存好也没退回的（进程中途挂了）自己作废', async () => {
    const store = app.get(DiagnosticStore);
    await redis().hset(RedisKeys.diagnosticUsage(), { bytes: diagnosticStoreMaxBytes - 1500, files: 0 });
    expect(await store.reserve(1000)).not.toBeNull();
    expect(await store.reserve(1000)).toBeNull();
    const [member] = await redis().zrange(RedisKeys.diagnosticReservations(), 0, -1);
    await redis().zadd(RedisKeys.diagnosticReservations(), Date.now() - 1, member);
    expect(await store.reserve(1000)).not.toBeNull();
    expect(await reservations()).toEqual([1000]);
  });
});

// 11-28 Codex 复核 F06：存好的累加与清理的整笔重写原来没有协调，清理列完目录后才存好的包会被旧统计盖掉。现在存好、删除、清理与重建在同一把锁里。
describe('诊断包：目录与已存好的账一致', () => {
  // 目录里实际存好的包（不含残片）。
  const disk = async () => {
    let bytes = 0, files = 0;
    for (const name of await readdir(dir())) {
      if (!/^[0-9A-HJKMNP-TV-Z]{8}$/.test(name)) continue;
      bytes += (await stat(join(dir(), name))).size;
      files++;
    }
    return { bytes: String(bytes), files: String(files) };
  };
  const exists = async (name: string) => (await readdir(dir())).includes(name);
  const until = async (check: () => Promise<boolean>) => {
    for (let attempt = 0; attempt < 300; attempt++) {
      if (await check()) return;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error('timed out');
  };
  const settled = <T>(promise: Promise<T>) => {
    const state = { done: false };
    void promise.then(() => (state.done = true), () => (state.done = true));
    return state;
  };

  it('清理正在列目录、重算（拿着锁）时存好一个包：改名与记账等清理写完再做，最后已存好的账等于目录', async () => {
    const store = app.get(DiagnosticStore);
    await upload(randomBytes(300)).expect(200);
    let release!: () => void, reached!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve)), arrived = new Promise<void>((resolve) => (reached = resolve));
    // 清理整个在锁里：别人拿着这把锁停住，就是清理正做到一半。
    const sweeping = app.get(DistributedLock).exclusive('diagnostic_store', 60, 1000, async () => {
      reached();
      await gate;
    });
    await arrived;
    const reservation = (await store.reserve(700))!;
    const saving = store.save('ABCDEFGH', Readable.from([randomBytes(700)]), reservation);
    const state = settled(saving);
    await until(() => exists('ABCDEFGH.part'));
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(state.done, '存好要等锁').toBe(false);
    expect(await exists('ABCDEFGH'), '还没改名').toBe(false);
    expect(await usage()).toEqual({ bytes: '300', files: '1' });
    release();
    await sweeping;
    await saving;
    expect(await usage()).toEqual(await disk());
    await app.get(DiagnosticRetentionTask).sweep();
    expect(await usage()).toEqual({ bytes: '1000', files: '2' });
  });

  it('存好正在记账、改名（拿着锁）时清理任务开跑：清理等它做完再列目录，最后已存好的账等于目录', async () => {
    const store = app.get(DiagnosticStore);
    await upload(randomBytes(300)).expect(200);
    const client = redis(), original = client.eval.bind(client);
    let release!: () => void, reached!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve)), arrived = new Promise<void>((resolve) => (reached = resolve));
    vi.spyOn(client, 'eval').mockImplementation((async (...args: Parameters<Redis['eval']>) => {
      // 记账那一句之前停住（此时拿着目录锁）。
      if (String(args[0]).includes("redis.call('ZREM', KEYS[2], ARGV[1])")) {
        reached();
        await gate;
      }
      return original(...args);
    }) as Redis['eval']);
    const reservation = (await store.reserve(700))!;
    const saving = store.save('ABCDEFGJ', Readable.from([randomBytes(700)]), reservation);
    await arrived;
    const sweeping = app.get(DiagnosticRetentionTask).sweep();
    const state = settled(sweeping);
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(state.done, '清理要等锁').toBe(false);
    release();
    await saving;
    await sweeping;
    expect(await usage()).toEqual(await disk());
    expect(await usage()).toEqual({ bytes: '1000', files: '2' });
  });

  it('一起来的十几个上传、删除与几次清理交错跑完：已存好的账一笔不差地等于目录，在途预占清空', async () => {
    const store = app.get(DiagnosticStore);
    const kept: string[] = [];
    for (let index = 0; index < 4; index++) kept.push((await upload(randomBytes(200 + index)).expect(200)).body.id as string);
    const jobs: Promise<unknown>[] = [];
    for (let index = 0; index < 14; index++) {
      jobs.push(
        (async () => {
          const size = 100 + index * 37;
          const reservation = (await store.reserve(size))!;
          await store.save(`ABCDEF${'GHJKMNPQRSTVWXYZ'[index]}${index % 2 === 0 ? '0' : '1'}`, Readable.from([randomBytes(size)]), reservation);
        })(),
      );
      if (index % 4 === 0) jobs.push(app.get(DiagnosticRetentionTask).sweep());
      if (index % 5 === 0 && kept.length > 0) jobs.push(store.remove([kept.pop()!]));
    }
    await Promise.all(jobs);
    expect(await usage()).toEqual(await disk());
    expect(await reservations()).toEqual([]);
  });

  it('存好时那笔预占已经没了（上传超过租期、被当成过期清掉）：这次不收，不留文件与残片，已存好的账不变；接口回 503 请客户端重传', async () => {
    const store = app.get(DiagnosticStore);
    await upload(randomBytes(300)).expect(200);
    const reservation = (await store.reserve(500))!;
    await redis().zrem(RedisKeys.diagnosticReservations(), reservation);
    await expect(store.save('ABCDEFGK', Readable.from([randomBytes(500)]), reservation)).rejects.toBeInstanceOf(DiagnosticReservationLost);
    expect(await exists('ABCDEFGK')).toBe(false);
    expect(await exists('ABCDEFGK.part')).toBe(false);
    expect(await usage()).toEqual({ bytes: '300', files: '1' });

    vi.spyOn(store, 'save').mockRejectedValueOnce(new DiagnosticReservationLost());
    const response = await upload(randomBytes(400));
    expect(response.status).toBe(503);
    expect(response.body.code).toBe('MAILBOX_FULL');
    expect(await reservations()).toEqual([]);
  });

  it('Redis 丢了（已存好的账与预占都没了）：下一次预占先按目录重建再判上限；在途的上传存好时预占已不在，这次不收', async () => {
    const store = app.get(DiagnosticStore);
    for (const size of [300, 400]) await upload(randomBytes(size)).expect(200);
    const inFlight = (await store.reserve(600))!;
    await redis().flushdb();
    await expect(store.save('ABCDEFGM', Readable.from([randomBytes(600)]), inFlight)).rejects.toBeInstanceOf(DiagnosticReservationLost);
    expect(await store.reserve(100)).not.toBeNull();
    expect(await usage()).toEqual({ bytes: '700', files: '2' });
    // 重建后照样按上限判：把已存好的账写到只差一点。
    await redis().hset(RedisKeys.diagnosticUsage(), { bytes: diagnosticStoreMaxBytes - 50, files: 2 });
    expect(await store.reserve(100)).toBeNull();
  });

  it('已存好的账在预占与存好之间过期了：存好时先按目录重建再记这一笔，账照样等于目录', async () => {
    const store = app.get(DiagnosticStore);
    await upload(randomBytes(300)).expect(200);
    const reservation = (await store.reserve(800))!;
    await redis().del(RedisKeys.diagnosticUsage());
    await store.save('ABCDEFGN', Readable.from([randomBytes(800)]), reservation);
    expect(await usage()).toEqual(await disk());
    expect(await usage()).toEqual({ bytes: '1100', files: '2' });
  });

  it('删除（用户删、注销账号）在锁里减账：删完马上等于目录，不用等清理', async () => {
    const store = app.get(DiagnosticStore);
    const ids: string[] = [];
    for (const size of [300, 400, 500]) ids.push((await upload(randomBytes(size)).expect(200)).body.id as string);
    await store.remove([ids[1], 'ZZZZZZZZ']);
    expect(await usage()).toEqual(await disk());
    expect(await usage()).toEqual({ bytes: '800', files: '2' });
  });

  it('进程写到一半挂了（残片与预占都留着）：清理删掉一小时前的残片，过期的预占在下一次预占时丢掉，都不算进已存好的账', async () => {
    const store = app.get(DiagnosticStore);
    await upload(randomBytes(300)).expect(200);
    const orphan = (await store.reserve(900))!;
    await writeFile(join(dir(), 'ABCDEFGP.part'), randomBytes(450));
    const old = Date.now() / 1000 - 2 * 3600;
    await utimes(join(dir(), 'ABCDEFGP.part'), old, old);
    await redis().zadd(RedisKeys.diagnosticReservations(), Date.now() - 1, orphan);
    await app.get(DiagnosticRetentionTask).sweep();
    expect(await exists('ABCDEFGP.part')).toBe(false);
    expect(await usage()).toEqual({ bytes: '300', files: '1' });
    expect(await store.reserve(100)).not.toBeNull();
    expect(await reservations()).toEqual([100]);
  });
});

describe('认领到应用账号', () => {
  // 一个登录了应用账号的设备：注册设备后直接在库里登记账号（账号登录本身在 account.e2e.test.ts 测）。
  const signedIn = async () => {
    const device = new TestDevice(server);
    expect((await device.register()).status).toBe(200);
    const accountId = randomBytes(16).toString('base64url'), now = new Date();
    const database = app.get(DataSource);
    await insertAccount(database, accountId, now);
    await database.query('INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, device.deviceId, now, now]);
    return device;
  };
  const claimed = async (id: string) => (await app.get(DataSource).query('SELECT account_id AS accountId FROM diagnostic_upload WHERE diagnostic_id = ?', [id])) as { accountId: string }[];

  it('回执带一次性认领口令；登录了应用账号的设备凭它认领，列表里看得到；口令错、用过、没登录、别的账号都不行', async () => {
    const receipt = (await upload(randomBytes(300)).expect(200)).body as { id: string; claim: string };
    expect(receipt.claim).toMatch(/^[A-Za-z0-9_-]{22}$/);
    const owner = await signedIn(), other = await signedIn();
    const bare = new TestDevice(server);
    expect((await bare.register()).status).toBe(200);
    const notSignedIn = await bare.call('POST', `/v1/account/diagnostics/${receipt.id}/claim`, { claim: receipt.claim });
    expect(notSignedIn.status).toBe(404);
    expect(notSignedIn.body.code).toBe('ACCOUNT_NOT_FOUND');
    const wrong = await owner.call('POST', `/v1/account/diagnostics/${receipt.id}/claim`, { claim: 'A'.repeat(22) });
    expect(wrong.status).toBe(404);
    expect(wrong.body.code).toBe('DIAGNOSTIC_NOT_FOUND');
    const done = await owner.call('POST', `/v1/account/diagnostics/${receipt.id}/claim`, { claim: receipt.claim });
    expect(done.status).toBe(200);
    expect(done.body).toMatchObject({ id: receipt.id, bytes: 300 });
    expect(done.body.expiresAt - done.body.uploadedAt).toBe(diagnosticKeepDays * 86400_000);
    expect((await other.call('POST', `/v1/account/diagnostics/${receipt.id}/claim`, { claim: receipt.claim })).status).toBe(404);
    expect(await claimed(receipt.id)).toHaveLength(1);
    const listed = await owner.call('GET', '/v1/account/diagnostics');
    expect(listed.body.uploads.map((item: { id: string }) => item.id)).toEqual([receipt.id]);
    expect((await other.call('GET', '/v1/account/diagnostics')).body.uploads).toEqual([]);
    const malformed = await owner.call('POST', '/v1/account/diagnostics/abc/claim', { claim: receipt.claim });
    expect(malformed.status).toBe(400);
  });

  it('删除只能删自己账号下的：文件与记录一起删，别人删回 DIAGNOSTIC_NOT_FOUND', async () => {
    const receipt = (await upload(randomBytes(200)).expect(200)).body as { id: string; claim: string };
    const owner = await signedIn(), other = await signedIn();
    await owner.call('POST', `/v1/account/diagnostics/${receipt.id}/claim`, { claim: receipt.claim });
    const denied = await other.call('DELETE', `/v1/account/diagnostics/${receipt.id}`);
    expect(denied.status).toBe(404);
    expect(denied.body.code).toBe('DIAGNOSTIC_NOT_FOUND');
    expect(await readdir(dir())).toEqual([receipt.id]);
    expect((await owner.call('DELETE', `/v1/account/diagnostics/${receipt.id}`)).status).toBe(204);
    expect(await readdir(dir())).toEqual([]);
    expect(await claimed(receipt.id)).toEqual([]);
  });

  it('注销应用账号连带删认领过的包，没认领的包不动', async () => {
    const mine = (await upload(randomBytes(200)).expect(200)).body as { id: string; claim: string };
    const anonymous = (await upload(randomBytes(100)).expect(200)).body as { id: string };
    const owner = await signedIn();
    await owner.call('POST', `/v1/account/diagnostics/${mine.id}/claim`, { claim: mine.claim });
    expect((await owner.call('DELETE', '/v1/account')).status).toBe(204);
    expect(await readdir(dir())).toEqual([anonymous.id]);
    expect(await claimed(mine.id)).toEqual([]);
  });

  it('清理任务删到期的包时连同认领记录；认领满保留期多一天的记录兜底删掉', async () => {
    const receipt = (await upload(randomBytes(200)).expect(200)).body as { id: string; claim: string };
    const owner = await signedIn();
    await owner.call('POST', `/v1/account/diagnostics/${receipt.id}/claim`, { claim: receipt.claim });
    const seconds = (Date.now() - diagnosticKeepDays * 86400_000 - 60_000) / 1000;
    await utimes(join(dir(), receipt.id), seconds, seconds);
    const stray = randomBytes(5).toString('hex').toUpperCase().replace(/[ILOU]/g, '0').slice(0, 8);
    const old = new Date(Date.now() - (diagnosticKeepDays + 2) * 86400_000);
    await app.get(DataSource).query('INSERT INTO diagnostic_upload (diagnostic_id, account_id, bytes, create_time, update_time) VALUES (?, ?, ?, ?, ?)', [stray, 'gone', 1, old, old]);
    await app.get(DiagnosticRetentionTask).sweep();
    expect(await claimed(receipt.id)).toEqual([]);
    expect(await claimed(stray)).toEqual([]);
    expect((await owner.call('GET', '/v1/account/diagnostics')).body.uploads).toEqual([]);
  });
});
