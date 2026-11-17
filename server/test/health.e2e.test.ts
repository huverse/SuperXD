import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import request from 'supertest';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { ErrorMonitor } from 'src/common/error_monitor';
import { REDIS } from 'src/common/redis/redis.module';

// 就绪探测（人工决策见 src/common/error_monitor.ts）：用服务自己的连接查 MySQL 与 Redis，限时内都回应才 200。
// 后面的用例会弄坏这份应用的连接，所以单独一个文件、按顺序跑。
let app: NestExpressApplication;
let server: string;

beforeAll(async () => {
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
});

afterAll(async () => {
  await app.close();
});

describe('就绪探测', () => {
  it('MySQL 与 Redis 都能用时 200，带告警个数与构建版本', async () => {
    const response = await request(server).get('/v1/health/ready');
    expect(response.status).toBe(200);
    expect(response.body).toEqual({ ready: true, mysql: 'ok', redis: 'ok', alerts: 0, version: 'dev' });
  });

  it('告警过的签名个数随就绪探测给出（只有个数）', async () => {
    const monitor = app.get(ErrorMonitor);
    monitor.recordLog('[Retention] action=run errorType=QueryFailedError', 'Retention');
    monitor.tick();
    const response = await request(server).get('/v1/health/ready');
    expect(response.status).toBe(200);
    expect(response.body.alerts).toBe(1);
  });

  it('Redis 卡住时限时内回 503（timeout），恢复后又是 200', async () => {
    const config = env().redis;
    const pauser = new Redis({ host: config.host, port: config.port, password: config.password, lazyConnect: true });
    await pauser.connect();
    try {
      await pauser.call('CLIENT', 'PAUSE', '2500', 'ALL');
      const started = Date.now();
      const response = await request(server).get('/v1/health/ready');
      expect(Date.now() - started).toBeLessThan(2000);
      expect(response.status).toBe(503);
      expect(response.body).toMatchObject({ ready: false, mysql: 'ok', redis: 'timeout' });
      await pauser.call('CLIENT', 'UNPAUSE');
    } finally {
      pauser.disconnect();
    }
    const recovered = await request(server).get('/v1/health/ready');
    expect(recovered.status).toBe(200);
  });

  it('存活探测不看依赖：连接断了 /v1/health 照样 200，就绪探测 503（down）；连回来又是 200', async () => {
    const redis = app.get<Redis>(REDIS), dataSource = app.get(DataSource);
    redis.disconnect();
    await dataSource.destroy();
    const response = await request(server).get('/v1/health/ready');
    expect(response.status).toBe(503);
    expect(response.body).toMatchObject({ ready: false, mysql: 'down', redis: 'down' });
    expect((await request(server).get('/v1/health')).status).toBe(200);
    await redis.connect();
    await dataSource.initialize();
    expect((await request(server).get('/v1/health/ready')).status).toBe(200);
  });
});
