import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { createConnection } from 'mysql2/promise';
import { randomBytes } from 'node:crypto';
import { mkdir, rm, utimes, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { ConfigRevision } from 'src/modules/app_release/config_revision';
import { FlagAdminError, runFlagAdmin } from 'src/modules/flag_target/flag_admin';
import { FlagTargetService } from 'src/modules/flag_target/flag_target.service';
import { insertAccount } from './account_fixture';
import { TestDevice } from './test_device';

// 灰度点名（规则见 src/modules/flag_target/flag_target.service.ts）与第 2 版灰度配置的透传（app_release 的 GET /v1/app/flags）。
let app: NestExpressApplication;
let server: string;
let database: DataSource;
let stamp = Date.now() / 1000;

const flagsFile = () => join(env().releasesDir, 'flags.json');

const signedIn = async () => {
  const device = new TestDevice(server);
  expect((await device.register()).status).toBe(200);
  const accountId = randomBytes(16).toString('base64url');
  const now = new Date();
  await insertAccount(database, accountId, now);
  await database.query('INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, device.deviceId, now, now]);
  const [{ username }] = (await database.query('SELECT username FROM app_account WHERE account_id = ?', [accountId])) as { username: string }[];
  return { device, accountId, username };
};

const admin = async (args: string[], now = new Date()) => {
  const { host, port, username, password, database: name } = env().mysql;
  const connection = await createConnection({ host, port, user: username, password, database: name, timezone: 'Z' });
  try {
    return await runFlagAdmin(connection, app.get<Redis>(REDIS), args, now);
  } finally {
    await connection.end();
  }
};

const mine = async (device: TestDevice) => {
  const response = await device.call('GET', '/v1/flags/mine');
  expect(response.status, JSON.stringify(response.body)).toBe(200);
  return (response.body as { flags: { id: string; until: string | null }[] }).flags;
};

beforeAll(async () => {
  await mkdir(env().releasesDir, { recursive: true });
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  database = app.get(DataSource);
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
});

afterAll(async () => {
  await rm(flagsFile(), { force: true });
  await app.close();
});

describe('灰度点名', () => {
  it('没登录应用账号回 ACCOUNT_NOT_FOUND；没被点名的是空列表', async () => {
    const stranger = new TestDevice(server);
    expect((await stranger.register()).status).toBe(200);
    expect((await stranger.call('GET', '/v1/flags/mine')).body.code).toBe('ACCOUNT_NOT_FOUND');
    const { device, accountId } = await signedIn();
    expect(await mine(device)).toEqual([]);
    // 顺带回账号建立的时刻，客户端按它判 minAccountDays。
    const [{ created }] = (await database.query('SELECT create_time AS created FROM app_account WHERE account_id = ?', [accountId])) as { created: Date }[];
    expect((await device.call('GET', '/v1/flags/mine')).body.accountCreatedAt).toBe(new Date(created).toISOString());
  });

  it('管理命令点名、改到期、撤销与列出；只回这个账号没过期的；用户名不分大小写', async () => {
    const { device, username } = await signedIn();
    const other = await signedIn();
    expect(await admin(['grant', 'social.nearby', username.toUpperCase()])).toContain('一直开到撤销');
    expect(await admin(['grant', 'game.flash2', username, '--until', '2099-01-01T00:00+08:00'])).toContain('2098-12-31T16:00:00.000Z');
    await admin(['grant', 'social.nearby', other.username]);
    expect(await mine(device)).toEqual([
      { id: 'game.flash2', until: '2098-12-31T16:00:00.000Z' },
      { id: 'social.nearby', until: null },
    ]);
    // 再点一次是改到期时刻，不多一行。
    await admin(['grant', 'game.flash2', username, '--until', '2099-02-01T00:00Z']);
    expect((await mine(device)).find((flag) => flag.id === 'game.flash2')!.until).toBe('2099-02-01T00:00:00.000Z');
    expect(await admin(['list', 'social.nearby'])).toContain(username);
    expect(await admin(['revoke', 'social.nearby', username])).toContain('已撤销');
    expect(await admin(['revoke', 'social.nearby', username])).toContain('没有被点名');
    expect((await mine(device)).map((flag) => flag.id)).toEqual(['game.flash2']);
    expect((await mine(other.device)).map((flag) => flag.id)).toEqual(['social.nearby']);
  });

  it('管理命令的坏输入只报一句话：没有这个用户名、开关编号不合法、到期时刻不带时区或已过去', async () => {
    const { username } = await signedIn();
    await expect(admin(['grant', 'x.y', 'nobody_here'])).rejects.toThrow(FlagAdminError);
    await expect(admin(['grant', 'Bad Flag', username])).rejects.toThrow(/开关编号不合法/);
    await expect(admin(['grant', 'x.y', username, '--until', '2099-01-01T00:00'])).rejects.toThrow(/带时区/);
    await expect(admin(['grant', 'x.y', username, '--until', '2000-01-01T00:00Z'])).rejects.toThrow(/晚于现在/);
    await expect(admin(['oops', 'x.y', username])).rejects.toThrow(/用法/);
  });

  it('到期的不再回，清理任务删掉到期的；注销账号连带删掉它的点名', async () => {
    const { device, username, accountId } = await signedIn();
    const now = new Date();
    await admin(['grant', 'a.soon', username, '--until', new Date(now.getTime() + 60_000).toISOString()], now);
    await admin(['grant', 'a.long', username]);
    expect((await mine(device)).map((flag) => flag.id)).toEqual(['a.long', 'a.soon']);
    await database.query('UPDATE rollout_target SET expires_at = ? WHERE flag_id = ? AND account_id = ?', [new Date(now.getTime() - 1000), 'a.soon', accountId]);
    expect((await mine(device)).map((flag) => flag.id)).toEqual(['a.long']);
    await app.get(FlagTargetService).sweep();
    expect(Number(((await database.query('SELECT COUNT(*) AS count FROM rollout_target WHERE account_id = ?', [accountId])) as { count: string }[])[0].count)).toBe(1);
    expect((await device.call('DELETE', '/v1/account')).status).toBe(204);
    expect(Number(((await database.query('SELECT COUNT(*) AS count FROM rollout_target WHERE account_id = ?', [accountId])) as { count: string }[])[0].count)).toBe(0);
  });

  // 灰度改了立即生效（人工决策见 src/modules/app_release/config_revision.ts）。
  it('点名与撤销给账号下每台设备写点名版本，签名请求的回复头带出来；问点名认条件请求，没变回 304', async () => {
    const { device, username, accountId } = await signedIn();
    const second = new TestDevice(server);
    expect((await second.register()).status).toBe(200);
    const now = new Date();
    await database.query('INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, second.deviceId, now, now]);
    // 没点过名：没有回复头，ETag 是 0；带着 0 来回 304、不查库。
    const first = await device.call('GET', '/v1/flags/mine');
    expect(first.status).toBe(200);
    expect(first.headers['x-sxd-targets']).toBeUndefined();
    expect(first.headers.etag).toBe('"0"');
    expect((await device.call('GET', '/v1/flags/mine').set('if-none-match', '"0"')).status).toBe(304);
    const granted = new Date(now.getTime() + 5000);
    expect(await admin(['grant', 'toolbox.cinema', username], granted)).toContain('已通知 2 台设备');
    // 任何签名请求都带上新的点名版本；拿旧的来问就回全量。
    for (const each of [device, second]) expect((await each.call('GET', '/v1/account')).headers['x-sxd-targets']).toBe(String(granted.getTime()));
    const changed = await device.call('GET', '/v1/flags/mine').set('if-none-match', '"0"');
    expect(changed.status).toBe(200);
    expect(changed.body.flags).toEqual([{ id: 'toolbox.cinema', until: null }]);
    expect(changed.headers.etag).toBe(`"${granted.getTime()}"`);
    expect((await device.call('GET', '/v1/flags/mine').set('if-none-match', changed.headers.etag as string)).status).toBe(304);
    const revoked = new Date(granted.getTime() + 5000);
    expect(await admin(['revoke', 'toolbox.cinema', username], revoked)).toContain('已撤销');
    expect((await second.call('GET', '/v1/account')).headers['x-sxd-targets']).toBe(String(revoked.getTime()));
    // 没登录应用账号的设备没有点名版本，回复头里也没有。
    const stranger = new TestDevice(server);
    expect((await stranger.register()).headers['x-sxd-targets']).toBeUndefined();
  });
});

describe('第 2 版灰度配置', () => {
  const envelope = { signed: 'eyJ2ZXJzaW9uIjoyfQ', signatures: [{ keyId: 'notes-2026-11', sig: 'A'.repeat(86) }] };
  const write = async (content: unknown) => {
    await writeFile(flagsFile(), JSON.stringify(content));
    stamp += 10;
    await utimes(flagsFile(), stamp, stamp);
  };

  it('还没放文件时信封为空；放了原样透传信封；写坏了不往外发', async () => {
    await rm(flagsFile(), { force: true });
    // paused 是健康回报自动暂停的版本（不签名，见 app_health.e2e.test.ts），别的用例可能留下几条，这里只看它是数组。
    expect((await fetch(`${server}/v1/app/flags`).then((response) => response.json())) as unknown).toMatchObject({ version: 2, envelope: null, paused: expect.any(Array) });
    await write({ version: 2, envelope });
    expect((await fetch(`${server}/v1/app/flags`).then((response) => response.json())) as unknown).toMatchObject({ version: 2, envelope, paused: expect.any(Array) });
    await write({ version: 2, envelope, flags: [] });
    expect((await fetch(`${server}/v1/app/flags`)).status).toBe(500);
    await write({ version: 1, envelope });
    expect((await fetch(`${server}/v1/app/flags`)).status).toBe(500);
  });

  it('每条回复带公共配置的版本号；两份配置认条件请求，没变回 304、不计限流，换了文件版本号就变', async () => {
    const revision = app.get(ConfigRevision);
    await write({ version: 2, envelope });
    await revision.refresh();
    const before = revision.value!;
    for (const path of ['/v1/health', '/v1/app/notes', '/v1/flags/mine']) expect((await fetch(`${server}${path}`)).headers.get('x-sxd-config'), path).toBe(before);
    const full = await fetch(`${server}/v1/app/flags`);
    expect(full.status).toBe(200);
    expect(full.headers.get('etag')).toBe(`"${before}"`);
    for (const path of ['/v1/app/flags', '/v1/app/rollout']) {
      const again = await fetch(`${server}${path}`, { headers: { 'if-none-match': `"${before}"` } });
      expect(again.status, path).toBe(304);
      expect(await again.text(), path).toBe('');
    }
    // 304 只看内存里的版本号、不读文件：文件刚删掉、版本号还没重算时照样回 304。
    await rm(flagsFile(), { force: true });
    expect((await fetch(`${server}/v1/app/flags`, { headers: { 'if-none-match': `"${before}"` } })).status).toBe(304);
    await write({ version: 2, envelope });
    await revision.refresh();
    expect(revision.value).not.toBe(before);
    const changed = await fetch(`${server}/v1/app/flags`, { headers: { 'if-none-match': `"${before}"` } });
    expect(changed.status).toBe(200);
    expect(changed.headers.get('x-sxd-config')).toBe(revision.value);
  });
});
