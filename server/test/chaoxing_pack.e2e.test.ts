import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import request from 'supertest';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { base64url } from 'src/common/crypto/relay_crypto';
import { rateSubjectOf } from 'src/common/client_ip';
import { chaoxingPackMaxBytes, chaoxingPackPerHour, chaoxingPackPickupPerHour, chaoxingRequestMaxBytes } from 'src/common/relay_limits';
import { ChaoxingPackRetentionTask } from 'src/modules/chaoxing/chaoxing_pack_retention.task';

let app: NestExpressApplication;
let server: string;
let dataSource: DataSource;

beforeAll(async () => {
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  dataSource = app.get(DataSource);
  await dataSource.query('DELETE FROM chaoxing_pack');
});

// 用例都从 127.0.0.1 发请求，每个用例前清空限流计数与上一轮投递的包，互不影响。
beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
  await dataSource.query('DELETE FROM chaoxing_pack');
});

afterEach(() => {
  vi.restoreAllMocks();
});

afterAll(async () => {
  await app.close();
});

const submit = (data: string) => request(server).post('/v1/chaoxing/packs').send({ data });
const pickup = (id: string) => request(server).post(`/v1/chaoxing/packs/${id}/pickup`).send({});
const revoke = (id: string, token: string) => request(server).post(`/v1/chaoxing/packs/${id}/revoke`).send({ token });

// 限流按小时固定窗口计数：把时钟钉在窗口中段，预置计数与再次请求不会恰好跨过整点而落到两个窗口。
const pinClock = () => {
  const middle = (Math.floor(Date.now() / 3600_000) + 0.5) * 3600_000;
  vi.spyOn(Date, 'now').mockReturnValue(middle);
};

// 把某个限流计数直接预置到上限（上限宽到每小时上千次，逐个发请求太慢）。
// ioredis 只给命令的 key 参数自动加 keyPrefix，SCAN 的 MATCH 模式与结果都不会动它：模式要自己拼前缀，结果要自己剥掉。
const fillRate = async (scope: string, limit: number) => {
  const redis = app.get<Redis>(REDIS);
  const prefix = redis.options.keyPrefix ?? '';
  const [, keys] = await redis.scan('0', 'MATCH', `${prefix}${RedisKeys.rate(scope, '*', 0).replace(/:0$/, '')}:*`, 'COUNT', 1000);
  expect(keys).toHaveLength(1);
  await redis.set(keys[0].slice(prefix.length), limit, 'KEEPTTL');
};

describe('代签凭据包', () => {
  it('提交后取走即删，重复取报 PACK_NOT_FOUND', async () => {
    const data = base64url(Buffer.from('pack-bytes'));
    const created = await submit(data).expect(200);
    expect(created.body.id).toMatch(/^[A-Za-z0-9_-]{16}$/);
    expect(created.body.expiresAt).toBeGreaterThan(Date.now());

    const taken = await pickup(created.body.id).expect(200);
    expect(taken.body.data).toBe(data);

    const again = await pickup(created.body.id).expect(404);
    expect(again.body.code).toBe('PACK_NOT_FOUND');
  });

  it('两个人同时取只有一个人拿到', async () => {
    const created = await submit(base64url(Buffer.from('race'))).expect(200);
    const results = await Promise.all([pickup(created.body.id), pickup(created.body.id)]);
    expect(results.filter((response) => response.status === 200)).toHaveLength(1);
    expect(results.filter((response) => response.status === 404)).toHaveLength(1);
  });

  it('格式与大小不对的提交被拒', async () => {
    expect((await submit('').expect(400)).body.code).toBe('INVALID_REQUEST');
    expect((await submit('%%%').expect(400)).body.code).toBe('INVALID_REQUEST');
    expect((await submit(base64url(Buffer.alloc(chaoxingPackMaxBytes + 1))).expect(413)).body.code).toBe('ENVELOPE_TOO_LARGE');
  });

  it('取件号不存在的报 PACK_NOT_FOUND', async () => {
    const missing = await pickup('AbCdEf0123456789').expect(404);
    expect(missing.body.code).toBe('PACK_NOT_FOUND');
  });

  it('按来源 IP 限流，宽松上限之内照常放行', async () => {
    pinClock();
    await submit(base64url(Buffer.from('first'))).expect(200);
    await fillRate('chaoxing_pack', chaoxingPackPerHour);
    const limited = await submit(base64url(Buffer.from('over')));
    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
    expect(limited.body.retryAfter).toBe(1800);
  });

  it('取件也按来源 IP 限流', async () => {
    pinClock();
    await pickup('AbCdEf0123456789').expect(404);
    await fillRate('chaoxing_pack_pickup', chaoxingPackPickupPerHour);
    const limited = await pickup('AbCdEf0123456789');
    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
  });

  it('恰好 2KB 的包能投递，超过请求体上限的直接 413', async () => {
    await submit(base64url(Buffer.alloc(chaoxingPackMaxBytes, 7))).expect(200);
    const huge = await submit('A'.repeat(chaoxingRequestMaxBytes + 1));
    expect(huge.status).toBe(413);
    expect(huge.body.code).toBe('ENVELOPE_TOO_LARGE');
  });

  it('出示方凭口令作废后取不到；口令不对作废不了，重复作废也不报错', async () => {
    const created = await submit(base64url(Buffer.from('rotate'))).expect(200);
    expect(created.body.revokeToken).toMatch(/^[A-Za-z0-9_-]{22}$/);
    await revoke(created.body.id, 'X'.repeat(22)).expect(204);
    await revoke(created.body.id, created.body.revokeToken).expect(204);
    await pickup(created.body.id).expect(404);
    await revoke(created.body.id, created.body.revokeToken).expect(204);

    const kept = await submit(base64url(Buffer.from('kept'))).expect(200);
    await revoke(kept.body.id, 'X'.repeat(22)).expect(204);
    await pickup(kept.body.id).expect(200);
    expect((await revoke(kept.body.id, 'short').expect(400)).body.code).toBe('INVALID_REQUEST');
  });

  it('过期的包取不到，清理任务会删掉', async () => {
    await submit(base64url(Buffer.from('expiring'))).expect(200);
    await dataSource.query('UPDATE chaoxing_pack SET expire_time = DATE_SUB(NOW(3), INTERVAL 1 MINUTE)');
    const rows: { pickup_id: string }[] = await dataSource.query('SELECT pickup_id FROM chaoxing_pack');
    expect(rows).toHaveLength(1);
    await pickup(rows[0].pickup_id).expect(404);

    const fresh = await submit(base64url(Buffer.from('fresh'))).expect(200);
    await app.get(ChaoxingPackRetentionTask).sweep();
    const counts: { total: string | number }[] = await dataSource.query('SELECT COUNT(*) AS total FROM chaoxing_pack');
    expect(Number(counts[0].total)).toBe(1);
    await pickup(fresh.body.id).expect(200);
  });
});

describe('限流的来源聚合', () => {
  it('IPv4 与映射地址按完整地址，IPv6 按 /64', () => {
    expect(rateSubjectOf('203.0.113.7')).toBe('203.0.113.7');
    expect(rateSubjectOf('::ffff:203.0.113.7')).toBe('203.0.113.7');
    expect(rateSubjectOf('2001:db8:1:2:aaaa::1')).toBe('2001:db8:1:2::/64');
    expect(rateSubjectOf('2001:db8:1:2:bbbb:cccc:dddd:eeee')).toBe('2001:db8:1:2::/64');
    expect(rateSubjectOf('2001:db8::1')).toBe('2001:db8:0:0::/64');
    expect(rateSubjectOf('fe80::1%eth0')).toBe('fe80:0:0:0::/64');
  });
});
