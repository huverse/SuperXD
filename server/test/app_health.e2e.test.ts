import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { createConnection, Connection } from 'mysql2/promise';
import request from 'supertest';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { healthKeepDays, healthMinSamples, healthReportPerSourcePerHour } from 'src/common/relay_limits';
import { AppHealthService } from 'src/modules/app_health/app_health.service';
import { healthVerdict } from 'src/modules/app_health/app_health_rules';
import { runHealthAdmin } from 'src/modules/app_health/health_admin';
import { periodOf } from 'src/modules/challenge/challenge_calendar';

// 分批更新的健康回报、自动暂停与意见反馈（规则见 src/modules/app_health/app_health_rules.ts）。渠道用随机名，用例之间互不干扰。
let app: NestExpressApplication;
let server: string;
let database: DataSource;
let admin: Connection;

const today = () => periodOf(Date.now(), 'day', env().businessTimeZone).date;
const daysAgo = (days: number) => new Date(Date.parse(`${today()}T00:00:00Z`) - days * 86400_000).toISOString().slice(0, 10);
const channelOf = () => `t${Math.random().toString(36).slice(2, 10)}`;
const report = (body: Record<string, unknown>) => request(server).post('/v1/app/health').send(body);
const counts = async (channel: string) =>
  (await database.query('SELECT version_code AS versionCode, SUM(reports) AS reports, SUM(fatal) AS fatal FROM app_health_daily WHERE channel = ? GROUP BY version_code ORDER BY version_code', [channel])) as {
    versionCode: number;
    reports: string;
    fatal: string;
  }[];
// 直接往汇总里放一批（不经限流）。
const seed = (channel: string, versionCode: number, reports: number, fatal: number, day = daysAgo(1)) =>
  database.query('INSERT INTO app_health_daily (channel, platform, version_code, day, reports, fatal, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', [channel, 'android', versionCode, day, reports, fatal, new Date(), new Date()]);

beforeAll(async () => {
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  database = app.get(DataSource);
  const { host, port, username, password, database: name } = env().mysql;
  admin = await createConnection({ host, port, user: username, password, database: name, timezone: 'Z' });
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
});

afterAll(async () => {
  await admin.end();
  await app.close();
});

describe('判定', () => {
  it('新版致命率超过上一版两倍且高出 5 个百分点、两版样本都够才停；版本号最高的是新版', () => {
    const n = healthMinSamples;
    expect(healthVerdict([{ versionCode: 30, reports: n, fatal: Math.ceil(n * 0.2) }, { versionCode: 29, reports: n, fatal: Math.ceil(n * 0.02) }])).toBe(30);
    expect(healthVerdict([{ versionCode: 29, reports: n, fatal: Math.ceil(n * 0.02) }, { versionCode: 30, reports: n, fatal: Math.ceil(n * 0.2) }])).toBe(30);
    expect(healthVerdict([{ versionCode: 30, reports: n - 1, fatal: n - 1 }, { versionCode: 29, reports: n, fatal: 0 }])).toBeNull();
    expect(healthVerdict([{ versionCode: 30, reports: 1000, fatal: 30 }, { versionCode: 29, reports: 1000, fatal: 10 }])).toBeNull();
    expect(healthVerdict([{ versionCode: 30, reports: 1000, fatal: 300 }, { versionCode: 29, reports: 1000, fatal: 200 }])).toBeNull();
    expect(healthVerdict([{ versionCode: 30, reports: 1000, fatal: 300 }])).toBeNull();
  });
});

describe('健康回报', () => {
  it('按渠道、版本、日累加份数与致命份数；今天、将来与太早的那天不收（照样 204）；不带多余字段', async () => {
    const channel = channelOf();
    for (const fatal of [false, true, false]) expect((await report({ channel, platform: 'android', versionCode: 30, day: daysAgo(1), fatal })).status).toBe(204);
    expect((await report({ channel, platform: 'ios', versionCode: 30, day: daysAgo(2), fatal: true })).status).toBe(204);
    for (const day of [today(), daysAgo(-1), daysAgo(8)]) expect((await report({ channel, platform: 'android', versionCode: 30, day, fatal: true })).status).toBe(204);
    expect(await counts(channel)).toEqual([{ versionCode: 30, reports: '4', fatal: '2' }]);
    for (const bad of [
      { channel, platform: 'web', versionCode: 30, day: daysAgo(1), fatal: true },
      { channel, platform: 'android', versionCode: 0, day: daysAgo(1), fatal: true },
      { channel, platform: 'android', versionCode: 30, day: '2026-1-1', fatal: true },
      { channel, platform: 'android', versionCode: 30, day: daysAgo(1), fatal: 'yes' },
      { channel, platform: 'android', versionCode: 30, day: daysAgo(1), fatal: true, deviceId: 'x' },
    ]) {
      expect((await report(bad)).body.code, JSON.stringify(bad)).toBe('INVALID_REQUEST');
    }
  });

  it('同一来源每小时超过上限回 RATE_LIMITED', async () => {
    const channel = channelOf();
    for (let index = 0; index < healthReportPerSourcePerHour; index++) await report({ channel, platform: 'android', versionCode: 30, day: daysAgo(1), fatal: false });
    expect((await report({ channel, platform: 'android', versionCode: 30, day: daysAgo(1), fatal: false })).body.code).toBe('RATE_LIMITED');
  });

  it('新版明显更差就自动暂停，/v1/app/flags 带上（不签名）；解除后不再自动停这一版；只看最近几天', async () => {
    const channel = channelOf();
    const service = app.get(AppHealthService);
    await seed(channel, 30, 100, 20);
    await seed(channel, 29, 100, 2);
    await seed(channel, 28, 1000, 900, daysAgo(10));
    await service.watch();
    const flags = await request(server).get('/v1/app/flags');
    expect(flags.body.paused).toContain(`app_update.${channel}.30`);
    expect(await runHealthAdmin(admin, ['status', channel])).toContain('30 停着');
    expect(await runHealthAdmin(admin, ['resume', channel, '30'])).toContain('已解除');
    expect(await runHealthAdmin(admin, ['resume', channel, '30'])).toContain('没有停着');
    await service.watch();
    expect((await request(server).get('/v1/app/flags')).body.paused).not.toContain(`app_update.${channel}.30`);
    // 差不多的新旧两版不停。
    const calm = channelOf();
    await seed(calm, 30, 100, 3);
    await seed(calm, 29, 100, 2);
    await service.watch();
    expect((await request(server).get('/v1/app/flags')).body.paused).not.toContain(`app_update.${calm}.30`);
  });

  it('汇总与意见保留 90 天', async () => {
    const channel = channelOf();
    await seed(channel, 30, 5, 0, daysAgo(healthKeepDays + 1));
    await seed(channel, 30, 5, 0, daysAgo(1));
    await database.query('INSERT INTO app_feedback (channel, platform, version_code, good, text, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?)', [channel, 'android', 30, 1, '旧', new Date(Date.now() - (healthKeepDays + 1) * 86400_000), new Date()]);
    await app.get(AppHealthService).sweep();
    expect(await counts(channel)).toEqual([{ versionCode: 30, reports: '5', fatal: '0' }]);
    expect(await runHealthAdmin(admin, ['feedback', channel, '30'])).toContain('好 0 条');
  });
});

describe('意见反馈', () => {
  it('好或不好加一句话，匿名；超过 200 字、多余字段不收；维护命令看汇总与最近的话', async () => {
    const channel = channelOf();
    const send = (body: Record<string, unknown>) => request(server).post('/v1/app/feedback').send(body);
    expect((await send({ channel, platform: 'android', versionCode: 30, good: true, text: '  更流畅了 ' })).status).toBe(204);
    expect((await send({ channel, platform: 'ios', versionCode: 30, good: false, text: '' })).status).toBe(204);
    expect((await send({ channel, platform: 'android', versionCode: 30, good: false, text: '字'.repeat(201) })).body.code).toBe('INVALID_REQUEST');
    expect((await send({ channel, platform: 'android', versionCode: 30, good: false, text: 'x', account: 'a' })).body.code).toBe('INVALID_REQUEST');
    const summary = await runHealthAdmin(admin, ['feedback', channel, '30']);
    expect(summary).toContain('好 1 条，不好 1 条');
    expect(summary).toContain('好\t更流畅了');
    await expect(runHealthAdmin(admin, ['feedback', channel, 'x'])).rejects.toThrow(/版本号/);
  });
});
