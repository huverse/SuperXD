import { createCipheriv, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { accountDeviceLimit, accountJoinPerSourcePerHour, accountLoginPerUserSourcePerHour, accountRegisterPerDevicePerHour } from 'src/common/relay_limits';
import { decodeBase64url } from 'src/common/crypto/relay_crypto';
import { openAccountSeal, x25519PrivateKey, x25519PublicOf } from 'src/modules/account/account_keys';
import { AccountRetentionTask } from 'src/modules/account/account_retention.task';
import { IpRegion } from 'src/common/ip_region';
import { TestDevice } from './test_device';

// 应用账号（人工决策见 src/modules/account/account.service.ts）：用户名加密码，密码与恢复码封装后交来，库里只有 scrypt 哈希。合成数据。

// 测试里的客户端封装（同 lib/social/account_seal.dart），中转公钥由测试私钥推出。
const testSealPrivate = x25519PrivateKey(decodeBase64url(process.env.RELAY_ACCOUNT_SEAL_KEY!, 32)!);
const testSealPublic = x25519PublicOf(testSealPrivate);
const x25519SpkiPrefix = Buffer.from('302a300506032b656e032100', 'hex');
const seal = (secrets: Record<string, unknown>, deviceId: string) => {
  const ephemeral = generateKeyPairSync('x25519');
  const ephemeralPublic = Buffer.from(ephemeral.publicKey.export({ format: 'jwk' }).x!, 'base64url');
  const shared = diffieHellman({ privateKey: ephemeral.privateKey, publicKey: createPublicKey({ key: Buffer.concat([x25519SpkiPrefix, testSealPublic]), format: 'der', type: 'spki' }) });
  const key = Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeralPublic, testSealPublic]), 'SXD1-account-sign-in', 32));
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.concat([Buffer.from([1]), ephemeralPublic, Buffer.from(deviceId, 'utf8')]));
  const body = Buffer.concat([cipher.update(JSON.stringify(secrets), 'utf8'), cipher.final()]);
  return Buffer.concat([Buffer.from([1]), ephemeralPublic, nonce, body, cipher.getAuthTag()]).toString('base64url');
};

let app: NestExpressApplication;
let server: string;
let database: DataSource;
let serial = 0;
const name = () => `tester_${Date.now() % 1e6}_${serial++}`;
// 恢复码是 24 位 Crockford base32（客户端生成）。
const recoveryCode = () => randomBytes(24).toString('hex').toUpperCase().replace(/[ILOU]/g, '0').slice(0, 24);

const keys = (device: TestDevice) => ({ signPublicKey: device.signPublicKey, boxPublicKey: device.boxPublicKey });
const register = (device: TestDevice, username: string, password = 'synthetic-pass', code = recoveryCode()) =>
  device.call('POST', '/v1/account/register', { ...keys(device), username, sealed: seal({ password, recoveryCode: code }, device.deviceId) });
const login = (device: TestDevice, username: string, password = 'synthetic-pass', sealedFor = device.deviceId) =>
  device.call('POST', '/v1/account/login', { ...keys(device), username, sealed: seal({ password }, sealedFor) });
const recover = (device: TestDevice, username: string, code: string, password: string, newRecoveryCode: string) =>
  device.call('POST', '/v1/account/recover', { ...keys(device), username, sealed: seal({ recoveryCode: code, password, newRecoveryCode }, device.deviceId) });
const registered = async (username = name()) => {
  const device = new TestDevice(server);
  const response = await register(device, username);
  expect(response.status).toBe(200);
  return { device, username, accountId: response.body.accountId as string };
};

beforeAll(async () => {
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  database = app.get(DataSource);
});

beforeEach(async () => {
  await app.get<Redis>(REDIS).flushdb();
});

afterAll(async () => {
  await app.close();
});

describe('信封', () => {
  it('打得开客户端封装的向量，换设备号或改一个字节就打不开', () => {
    const vector = JSON.parse(readFileSync(new URL('./vectors/account_seal_v1.json', import.meta.url), 'utf8')) as { recipientSeed: string; recipientPublic: string; deviceId: string; proof: Record<string, string>; sealed: string };
    const privateKey = x25519PrivateKey(decodeBase64url(vector.recipientSeed, 32)!);
    const publicKey = x25519PublicOf(privateKey);
    expect(publicKey.toString('base64url')).toBe(vector.recipientPublic);
    const sealed = decodeBase64url(vector.sealed)!;
    expect(JSON.parse(openAccountSeal(sealed, vector.deviceId, privateKey, publicKey)!.toString('utf8'))).toEqual(vector.proof);
    expect(openAccountSeal(sealed, 'BBBBBBBBBBBBBBBBBBBBBB', privateKey, publicKey)).toBeNull();
    const tampered = Buffer.from(sealed);
    tampered[60] ^= 1;
    expect(openAccountSeal(tampered, vector.deviceId, privateKey, publicKey)).toBeNull();
  });
});

describe('注册与登录', () => {
  it('注册：用户名不分大小写、先到先得；库里只有 scrypt 哈希，没有密码与恢复码原文', async () => {
    const username = name();
    const device = new TestDevice(server);
    const code = recoveryCode();
    const response = await register(device, username.toUpperCase(), 'synthetic-pass', code);
    expect(response.body).toMatchObject({ accountId: expect.stringMatching(/^[A-Za-z0-9_-]{22}$/), username });
    expect((await device.call('GET', '/v1/account')).body).toMatchObject({ accountId: response.body.accountId, username, deviceCount: 1 });
    const [row] = (await database.query('SELECT password_hash AS passwordHash, recovery_hash AS recoveryHash FROM app_account WHERE account_id = ?', [response.body.accountId])) as { passwordHash: string; recoveryHash: string }[];
    expect(row.passwordHash).toMatch(/^scrypt\$32768\$8\$1\$/);
    expect(row.passwordHash).not.toContain('synthetic-pass');
    expect(row.recoveryHash).not.toContain(code);
    const other = new TestDevice(server);
    expect((await register(other, username)).body.code).toBe('USERNAME_TAKEN');
    expect((await other.call('GET', '/v1/account')).body.code).toBe('UNAUTHORIZED');
  });

  it('登录：密码对就把这把设备密钥登记到账号；密码或用户名不对都只回 CREDENTIALS_INVALID', async () => {
    const { username, accountId } = await registered();
    const second = new TestDevice(server);
    expect((await login(second, username, 'wrong-pass')).body.code).toBe('CREDENTIALS_INVALID');
    expect((await login(second, `${username}x`)).body.code).toBe('CREDENTIALS_INVALID');
    const response = await login(second, username.toUpperCase());
    expect(response.body).toMatchObject({ accountId, username });
    expect((await second.call('GET', '/v1/account')).body.deviceCount).toBe(2);
  });

  it('封给别的设备、少一项多一项、密码太短的秘密一律不认', async () => {
    const device = new TestDevice(server);
    const body = (sealed: string) => ({ ...keys(device), username: name(), sealed });
    for (const sealed of [
      seal({ password: 'synthetic-pass', recoveryCode: recoveryCode() }, 'BBBBBBBBBBBBBBBBBBBBBB'),
      seal({ password: 'synthetic-pass' }, device.deviceId),
      seal({ password: 'synthetic-pass', recoveryCode: recoveryCode(), extra: '1' }, device.deviceId),
      seal({ password: 'short', recoveryCode: recoveryCode() }, device.deviceId),
      seal({ password: 'synthetic-pass', recoveryCode: 'not-a-code' }, device.deviceId),
    ]) {
      expect((await device.call('POST', '/v1/account/register', body(sealed))).body.code).toBe('INVALID_REQUEST');
    }
    expect((await device.call('POST', '/v1/account/register', { ...keys(device), username: '用户', sealed: seal({ password: 'synthetic-pass', recoveryCode: recoveryCode() }, device.deviceId) })).status).toBe(400);
  });

  it('同一用户名同一来源每小时尝试有上限；每台设备每小时注册有上限', async () => {
    const { username } = await registered();
    const device = new TestDevice(server);
    for (let index = 0; index < accountLoginPerUserSourcePerHour; index++) await login(device, username, 'wrong-pass');
    expect((await login(device, username)).body.code).toBe('RATE_LIMITED');
    const busy = new TestDevice(server);
    for (let index = 0; index < accountRegisterPerDevicePerHour; index++) await register(busy, name());
    expect((await register(busy, name())).body.code).toBe('RATE_LIMITED');
  });
});

describe('忘了密码', () => {
  it('凭恢复码设新密码并换恢复码，旧密码与旧恢复码都作废；这台设备随之登录', async () => {
    const username = name();
    const owner = new TestDevice(server);
    const code = recoveryCode();
    const accountId = (await register(owner, username, 'synthetic-pass', code)).body.accountId as string;
    const fresh = new TestDevice(server);
    expect((await recover(fresh, username, recoveryCode(), 'new-synthetic', recoveryCode())).body.code).toBe('CREDENTIALS_INVALID');
    const next = recoveryCode();
    expect((await recover(fresh, username, code, 'new-synthetic', next)).body).toMatchObject({ accountId, username });
    expect((await fresh.call('GET', '/v1/account')).body.accountId).toBe(accountId);
    const another = new TestDevice(server);
    expect((await login(another, username, 'synthetic-pass')).body.code).toBe('CREDENTIALS_INVALID');
    expect((await login(another, username, 'new-synthetic')).body.accountId).toBe(accountId);
    expect((await recover(new TestDevice(server), username, code, 'third-synthetic', recoveryCode())).body.code).toBe('CREDENTIALS_INVALID');
    expect((await recover(new TestDevice(server), username, next, 'third-synthetic', recoveryCode())).body.accountId).toBe(accountId);
  });

  // [人工决策-2026-11-15 19:18:31] 恢复码重设后账号下其他设备都下线，改密码不动（用户选推荐）。
  it('凭恢复码重设后账号下别的设备都下线、只留发起重设的这台；登录着改密码不动别的设备', async () => {
    const username = name();
    const owner = new TestDevice(server);
    const code = recoveryCode();
    await register(owner, username, 'synthetic-pass', code);
    const other = new TestDevice(server);
    await login(other, username);
    expect((await owner.call('POST', '/v1/account/password', { sealed: seal({ password: 'changed-synthetic' }, owner.deviceId) })).status).toBe(204);
    expect((await other.call('GET', '/v1/account')).body.deviceCount).toBe(2);
    const fresh = new TestDevice(server);
    expect((await recover(fresh, username, code, 'new-synthetic', recoveryCode())).status).toBe(200);
    expect((await fresh.call('GET', '/v1/account')).body.deviceCount).toBe(1);
    expect((await owner.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
    expect((await other.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
  });

  it('登录着的设备直接改密码、换恢复码（不要旧密码）；没登录的不行', async () => {
    const { device, username, accountId } = await registered();
    expect((await device.call('POST', '/v1/account/password', { sealed: seal({ password: 'changed-synthetic' }, device.deviceId) })).status).toBe(204);
    expect((await login(new TestDevice(server), username, 'changed-synthetic')).body.accountId).toBe(accountId);
    const code = recoveryCode();
    expect((await device.call('POST', '/v1/account/recovery-code', { sealed: seal({ recoveryCode: code }, device.deviceId) })).status).toBe(204);
    expect((await recover(new TestDevice(server), username, code, 'again-synthetic', recoveryCode())).body.accountId).toBe(accountId);
    const stranger = new TestDevice(server);
    await stranger.register();
    expect((await stranger.call('POST', '/v1/account/password', { sealed: seal({ password: 'changed-synthetic' }, stranger.deviceId) })).body.code).toBe('ACCOUNT_NOT_FOUND');
  });
});

describe('扫码登录', () => {
  it('新设备出示二维码，已登录的设备核对码批准后加进账号；新设备轮询拿到账号', async () => {
    const { device: owner, username, accountId } = await registered();
    const fresh = new TestDevice(server);
    const join = await fresh.call('POST', '/v1/account/joins', keys(fresh));
    const { ticketId, code } = join.body as { ticketId: string; code: string };
    expect(code).toMatch(/^\d{6}$/);
    expect((await fresh.call('GET', `/v1/account/joins/${ticketId}`)).body).toEqual({ state: 'pending', account: null });
    expect((await owner.call('POST', `/v1/account/joins/${ticketId}/approve`, { code })).status).toBe(204);
    expect((await fresh.call('GET', `/v1/account/joins/${ticketId}`)).body).toMatchObject({ state: 'approved', account: { accountId, username } });
    expect((await fresh.call('GET', '/v1/account')).body).toMatchObject({ accountId, deviceCount: 2 });
  });

  // [人工决策-2026-11-15 19:18:31] 批准前给批准方看请求方的机型与按 IP 查出的属地（用户选推荐）：IP 原文不进票据、不进日志。
  it('出示时带上机型，服务器按来源 IP 查属地记进票据（不存 IP）；批准方先看票据拿到机型与属地，码不对或没登录看不了', async () => {
    const { device: owner } = await registered();
    const fresh = new TestDevice(server);
    const lookup = vi.spyOn(app.get(IpRegion), 'regionOf').mockResolvedValueOnce('广东省深圳市');
    const { ticketId, code } = (await fresh.call('POST', '/v1/account/joins', { ...keys(fresh), device: 'Xiaomi 23127PN0CC' })).body as { ticketId: string; code: string };
    expect(lookup).toHaveBeenCalledWith(expect.stringMatching(/127\.0\.0\.1$/));
    const raw = (await app.get<Redis>(REDIS).get(RedisKeys.accountJoin(ticketId)))!;
    expect(raw).not.toContain('127.0.0.1');
    expect((await owner.call('POST', `/v1/account/joins/${ticketId}/inspect`, { code })).body).toEqual({ device: 'Xiaomi 23127PN0CC', region: '广东省深圳市' });
    const wrong = code === '000000' ? '000001' : '000000';
    expect((await owner.call('POST', `/v1/account/joins/${ticketId}/inspect`, { code: wrong })).body.code).toBe('JOIN_NOT_FOUND');
    const stranger = new TestDevice(server);
    await stranger.register();
    expect((await stranger.call('POST', `/v1/account/joins/${ticketId}/inspect`, { code })).body.code).toBe('ACCOUNT_NOT_FOUND');
    expect((await fresh.call('POST', `/v1/account/joins/${ticketId}/inspect`, { code })).body.code).toBe('JOIN_NOT_FOUND');
    // 旧客户端不带机型、查不出属地时都是空。
    const old = new TestDevice(server);
    const second = (await old.call('POST', '/v1/account/joins', keys(old))).body as { ticketId: string; code: string };
    expect((await owner.call('POST', `/v1/account/joins/${second.ticketId}/inspect`, { code: second.code })).body).toEqual({ device: null, region: null });
    expect((await old.call('POST', '/v1/account/joins', { ...keys(old), device: 'a\u0000b' })).status).toBe(400);
    expect((await old.call('POST', '/v1/account/joins', { ...keys(old), device: 'x'.repeat(65) })).status).toBe(400);
  });

  // [人工决策-2026-11-15 19:18:31] 离开出示页时作废票据（用户选推荐）：只有出示的那台能作废、只作废还没批准的。
  it('新设备离开出示页时自己作废票据：作废后批准不认；别的设备作废不了；批准过的作废不动', async () => {
    const { device: owner, accountId } = await registered();
    const fresh = new TestDevice(server);
    const first = (await fresh.call('POST', '/v1/account/joins', keys(fresh))).body as { ticketId: string; code: string };
    expect((await owner.call('DELETE', `/v1/account/joins/${first.ticketId}`)).status).toBe(204);
    expect((await owner.call('POST', `/v1/account/joins/${first.ticketId}/approve`, { code: first.code })).status).toBe(204);
    const second = (await fresh.call('POST', '/v1/account/joins', keys(fresh))).body as { ticketId: string; code: string };
    expect((await fresh.call('DELETE', `/v1/account/joins/${second.ticketId}`)).status).toBe(204);
    expect((await owner.call('POST', `/v1/account/joins/${second.ticketId}/approve`, { code: second.code })).body.code).toBe('JOIN_NOT_FOUND');
    const late = new TestDevice(server);
    const third = (await late.call('POST', '/v1/account/joins', keys(late))).body as { ticketId: string; code: string };
    expect((await owner.call('POST', `/v1/account/joins/${third.ticketId}/approve`, { code: third.code })).status).toBe(204);
    expect((await late.call('DELETE', `/v1/account/joins/${third.ticketId}`)).status).toBe(204);
    expect((await late.call('GET', `/v1/account/joins/${third.ticketId}`)).body).toMatchObject({ state: 'approved', account: { accountId } });
    expect((await fresh.call('DELETE', `/v1/account/joins/${second.ticketId}`)).status).toBe(204);
  });

  it('核对码不对、没登录的设备批准、别的设备来问、票据过期都不认', async () => {
    const { device: owner } = await registered();
    const fresh = new TestDevice(server);
    const { ticketId, code } = (await fresh.call('POST', '/v1/account/joins', keys(fresh))).body as { ticketId: string; code: string };
    const wrong = code === '000000' ? '000001' : '000000';
    expect((await owner.call('POST', `/v1/account/joins/${ticketId}/approve`, { code: wrong })).body.code).toBe('JOIN_NOT_FOUND');
    const stranger = new TestDevice(server);
    await stranger.register();
    expect((await stranger.call('POST', `/v1/account/joins/${ticketId}/approve`, { code })).body.code).toBe('ACCOUNT_NOT_FOUND');
    expect((await owner.call('GET', `/v1/account/joins/${ticketId}`)).body.code).toBe('JOIN_NOT_FOUND');
    await app.get<Redis>(REDIS).del(RedisKeys.accountJoin(ticketId));
    expect((await owner.call('POST', `/v1/account/joins/${ticketId}/approve`, { code })).body.code).toBe('JOIN_NOT_FOUND');
    expect((await fresh.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
  });

  it('已被一个账号批准的票据，别的账号再批不认（新设备留在先批准的账号），同一账号重发照旧成功', async () => {
    const { device: owner, accountId } = await registered();
    const { device: other } = await registered();
    const fresh = new TestDevice(server);
    const { ticketId, code } = (await fresh.call('POST', '/v1/account/joins', keys(fresh))).body as { ticketId: string; code: string };
    expect((await owner.call('POST', `/v1/account/joins/${ticketId}/approve`, { code })).status).toBe(204);
    expect((await other.call('POST', `/v1/account/joins/${ticketId}/approve`, { code })).body.code).toBe('JOIN_NOT_FOUND');
    expect((await owner.call('POST', `/v1/account/joins/${ticketId}/approve`, { code })).status).toBe(204);
    expect((await fresh.call('GET', `/v1/account/joins/${ticketId}`)).body).toMatchObject({ state: 'approved', account: { accountId } });
    expect((await fresh.call('GET', '/v1/account')).body.accountId).toBe(accountId);
  });

  it(`同一来源每小时出示二维码的新设备最多 ${accountJoinPerSourcePerHour} 台（每台都会登记设备），同一台重新出示不计`, async () => {
    const first = new TestDevice(server);
    for (let index = 0; index < 3; index++) expect((await first.call('POST', '/v1/account/joins', keys(first))).status).toBe(200);
    for (let index = 1; index < accountJoinPerSourcePerHour; index++) {
      const device = new TestDevice(server);
      expect((await device.call('POST', '/v1/account/joins', keys(device))).status).toBe(200);
    }
    const extra = new TestDevice(server);
    expect((await extra.call('POST', '/v1/account/joins', keys(extra))).body.code).toBe('RATE_LIMITED');
    expect(await database.query('SELECT id FROM device WHERE device_id = ?', [extra.deviceId])).toHaveLength(0);
    expect((await first.call('POST', '/v1/account/joins', keys(first))).status).toBe(200);
  });
});

describe('退出、注销与保留', () => {
  it('退出账号就是删设备密钥：登记连带删除，另一台照常', async () => {
    const { device: first, username } = await registered();
    const second = new TestDevice(server);
    await login(second, username);
    expect((await first.call('DELETE', '/v1/devices')).status).toBe(204);
    expect((await first.call('GET', '/v1/account')).body.code).toBe('UNAUTHORIZED');
    expect((await second.call('GET', '/v1/account')).body.deviceCount).toBe(1);
  });

  // [人工决策-2026-11-15 19:18:31] 区分「账号已删」与「这把密钥不在账号里」（用户选推荐）：注销时给账号的设备记墓碑，它们再来回 ACCOUNT_DELETED，
  // 客户端只在这时清本机那个账号的私信；被顶掉、恢复码重设踢下线、退出的照旧 ACCOUNT_NOT_FOUND 或 UNAUTHORIZED。
  it('注销账号：别的设备密钥也不再属于它、再来回 ACCOUNT_DELETED，用户名空出来可以重新注册；墓碑满保留期由清理任务删', async () => {
    const { device: first, username, accountId } = await registered();
    const second = new TestDevice(server);
    await login(second, username);
    expect((await first.call('DELETE', '/v1/account')).status).toBe(204);
    expect((await second.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_DELETED');
    expect((await second.call('POST', '/v1/account/password', { sealed: seal({ password: 'changed-synthetic' }, second.deviceId) })).body.code).toBe('ACCOUNT_DELETED');
    expect((await first.call('DELETE', '/v1/account')).body.code).toBe('ACCOUNT_DELETED');
    const third = new TestDevice(server);
    await third.register();
    expect((await third.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
    const fresh = await register(second, username);
    expect(fresh.body.accountId).not.toBe(accountId);
    expect((await second.call('GET', '/v1/account')).body.accountId).toBe(fresh.body.accountId);
    await database.query('UPDATE account_tombstone SET create_time = ? WHERE device_id = ?', [new Date(Date.now() - 401 * 86400_000), first.deviceId]);
    await app.get(AccountRetentionTask).sweep();
    expect(await database.query('SELECT id FROM account_tombstone WHERE device_id = ?', [first.deviceId])).toHaveLength(0);
    expect((await first.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
  });

  it(`一个账号最多 ${accountDeviceLimit} 把设备密钥，再登录顶掉最久没用的`, async () => {
    const { device: first, username } = await registered();
    const devices = [first];
    for (let index = 0; index < accountDeviceLimit; index++) {
      // 按「用户名 + 来源」每小时 10 次：每 9 次清一下 Redis 里的计数。
      if (index % 9 === 0) await app.get<Redis>(REDIS).flushdb();
      const device = new TestDevice(server);
      expect((await login(device, username)).status).toBe(200);
      devices.push(device);
    }
    expect((await devices[accountDeviceLimit].call('GET', '/v1/account')).body.deviceCount).toBe(accountDeviceLimit);
    expect((await devices[0].call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
  });

  // [人工决策-2026-11-15 19:18:31] 账号下任一设备有签名请求就按小时记一次活跃（用户选推荐），400 天不活跃清理更准。
  it('账号下的设备有别的签名请求也记最后活跃，每台每小时最多写一次', async () => {
    const { device, accountId } = await registered();
    const lastSeen = async () => ((await database.query('SELECT last_seen_time AS lastSeen FROM app_account WHERE account_id = ?', [accountId])) as { lastSeen: Date }[])[0].lastSeen.getTime();
    const old = new Date(Date.now() - 300 * 86400_000);
    await database.query('UPDATE app_account SET last_seen_time = ? WHERE account_id = ?', [old, accountId]);
    await app.get<Redis>(REDIS).del(RedisKeys.seen(device.deviceId));
    expect((await device.call('GET', '/v1/points')).status).toBe(200);
    await vi.waitFor(async () => expect(await lastSeen()).toBeGreaterThan(Date.now() - 60_000));
    await database.query('UPDATE app_account SET last_seen_time = ? WHERE account_id = ?', [old, accountId]);
    expect((await device.call('GET', '/v1/points')).status).toBe(200);
    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(await lastSeen()).toBe(old.getTime());
  });

  it('400 天没登录也没查看的账号由清理任务删除', async () => {
    const { device, accountId } = await registered();
    await database.query('UPDATE app_account SET last_seen_time = ? WHERE account_id = ?', [new Date(Date.now() - 401 * 86400_000), accountId]);
    await app.get(AccountRetentionTask).sweep();
    expect((await device.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
    expect(await database.query('SELECT id FROM app_account WHERE account_id = ?', [accountId])).toHaveLength(0);
  });
});
