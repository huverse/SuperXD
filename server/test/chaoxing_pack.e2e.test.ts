import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import request from 'supertest';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { base64url } from 'src/common/crypto/relay_crypto';
import { chaoxingPackMaxBytes, chaoxingPackPerHour } from 'src/common/relay_limits';
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

afterAll(async () => {
  await app.close();
});

const submit = (data: string) => request(server).post('/v1/chaoxing/packs').send({ data });
const pickup = (id: string) => request(server).post(`/v1/chaoxing/packs/${id}/pickup`).send({});

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

  // 上限宽到每小时上千次，逐个发请求太慢：把本窗口的计数直接预置到上限，再发一次看是否被拦。
  it('按来源 IP 限流，宽松上限之内照常放行', async () => {
    await submit(base64url(Buffer.from('first'))).expect(200);
    // 计数键按实际来源 IP 生成（本机可能是 127.0.0.1 或 ::ffff:127.0.0.1），先投递一次再按前缀找到它。
    // ioredis 只给命令的 key 参数自动加 keyPrefix，SCAN 的 MATCH 模式与结果都不会动它：模式要自己拼前缀，结果要自己剥掉。
    const redis = app.get<Redis>(REDIS);
    const prefix = redis.options.keyPrefix ?? '';
    const [, keys] = await redis.scan('0', 'MATCH', `${prefix}${RedisKeys.rate('chaoxing_pack', '*', 0).replace(/:0$/, '')}:*`, 'COUNT', 1000);
    expect(keys).toHaveLength(1);
    await redis.set(keys[0].slice(prefix.length), chaoxingPackPerHour, 'KEEPTTL');
    const limited = await submit(base64url(Buffer.from('over')));
    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
  });

  it('过期的包取不到，清理任务会删掉', async () => {
    await submit(base64url(Buffer.from('expiring'))).expect(200);
    await dataSource.query('UPDATE chaoxing_pack SET expire_time = DATE_SUB(NOW(3), INTERVAL 1 MINUTE)');
    const rows: { pickup_id: string }[] = await dataSource.query('SELECT pickup_id FROM chaoxing_pack');
    expect(rows).toHaveLength(1);
    await pickup(rows[0].pickup_id).expect(404);

    await app.get(ChaoxingPackRetentionTask).sweep();
    const counts: { total: string | number }[] = await dataSource.query('SELECT COUNT(*) AS total FROM chaoxing_pack');
    expect(Number(counts[0].total)).toBe(0);
  });
});
