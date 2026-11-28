import { createCipheriv, createPrivateKey, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { Readable } from 'node:stream';
import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { accountDeviceLimit, accountJoinPerSourcePerHour, accountLoginPerUserSourcePerHour, accountRegisterPerDevicePerHour } from 'src/common/relay_limits';
import { accountDeletedCanonical, decodeBase64url, ed25519Key, verifyEd25519, x25519PrivateKey, x25519PublicOf } from 'src/common/crypto/relay_crypto';
import { AccountKeys, accountSealKeyId, accountSealKeyOf, openAccountSeal } from 'src/modules/account/account_keys';
import { AccountRetentionTask } from 'src/modules/account/account_retention.task';
import { AccountRepository } from 'src/modules/account/account.repository';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';
import { DiagnosticStore, newDiagnosticId } from 'src/modules/diagnostic/diagnostic.store';
import { claimHash } from 'src/modules/diagnostic/diagnostic.service';
import { DiagnosticUploadRepository } from 'src/modules/diagnostic/diagnostic_upload.repository';
import { ChallengeRepository } from 'src/modules/challenge/challenge.repository';
import { UnlockRepository } from 'src/modules/unlock/unlock.repository';
import { PassRepository } from 'src/modules/pass/pass.repository';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { env } from 'src/config/env';
import { IpRegion } from 'src/common/ip_region';
import { createInviteKeys, helloOf, inviteProof, socialBindBody, TestDevice } from './test_device';

// 应用账号（人工决策见 src/modules/account/account.service.ts）：用户名加密码，密码与恢复码封装后交来，库里只有 scrypt 哈希。合成数据。

// 测试里的客户端封装（同 lib/relay/account_seal.dart），中转公钥由测试私钥推出。
const testSealPrivate = x25519PrivateKey(decodeBase64url(process.env.RELAY_ACCOUNT_SEAL_KEY!, 32)!);
const testSealPublic = x25519PublicOf(testSealPrivate);
const x25519SpkiPrefix = Buffer.from('302a300506032b656e032100', 'hex');
// 第 2 版（11-17 起的客户端）：版本 2 后接钥号（中转公钥 sha256 的前 8 字节），钥号也进附加数据；keyId 给了就冒充别的钥号。
const sealKeyed = (secrets: Record<string, unknown>, deviceId: string, keyId = accountSealKeyId(testSealPublic)) => {
  const ephemeral = generateKeyPairSync('x25519');
  const ephemeralPublic = Buffer.from(ephemeral.publicKey.export({ format: 'jwk' }).x!, 'base64url');
  const shared = diffieHellman({ privateKey: ephemeral.privateKey, publicKey: createPublicKey({ key: Buffer.concat([x25519SpkiPrefix, testSealPublic]), format: 'der', type: 'spki' }) });
  const key = Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeralPublic, testSealPublic]), 'SXD1-account-sign-in', 32));
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  const header = Buffer.concat([Buffer.from([2]), keyId]);
  cipher.setAAD(Buffer.concat([header, ephemeralPublic, Buffer.from(deviceId, 'utf8')]));
  const body = Buffer.concat([cipher.update(JSON.stringify(secrets), 'utf8'), cipher.final()]);
  return Buffer.concat([header, ephemeralPublic, nonce, body, cipher.getAuthTag()]).toString('base64url');
};
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
  it('打得开旧客户端（第 1 版、没有钥号）封装的向量，换设备号或改一个字节就打不开', () => {
    const vector = JSON.parse(readFileSync(new URL('./vectors/account_seal_v1.json', import.meta.url), 'utf8')) as { recipientSeed: string; recipientPublic: string; deviceId: string; proof: Record<string, string>; sealed: string };
    const key = accountSealKeyOf(decodeBase64url(vector.recipientSeed, 32)!);
    expect(key.publicKey.toString('base64url')).toBe(vector.recipientPublic);
    const sealed = decodeBase64url(vector.sealed)!;
    expect(JSON.parse(openAccountSeal(sealed, vector.deviceId, [key])!.toString('utf8'))).toEqual(vector.proof);
    expect(openAccountSeal(sealed, 'BBBBBBBBBBBBBBBBBBBBBB', [key])).toBeNull();
    const tampered = Buffer.from(sealed);
    tampered[60] ^= 1;
    expect(openAccountSeal(tampered, vector.deviceId, [key])).toBeNull();
  });
});

describe('注册与登录', () => {
  // 账号封装钥带钥号（11-17）：新客户端发第 2 版，旧客户端的第 1 版照旧认；钥号不是服务器认的就当解不开。
  it('第 2 版信封（带钥号）注册与登录都认；钥号对不上回 INVALID_REQUEST；第 1 版照旧能登录', async () => {
    const username = name();
    const device = new TestDevice(server);
    const code = recoveryCode();
    expect((await device.call('POST', '/v1/account/register', { ...keys(device), username, sealed: sealKeyed({ password: 'synthetic-pass', recoveryCode: code }, device.deviceId) })).status).toBe(200);
    const keyed = new TestDevice(server);
    expect((await keyed.call('POST', '/v1/account/login', { ...keys(keyed), username, sealed: sealKeyed({ password: 'synthetic-pass' }, keyed.deviceId) })).status).toBe(200);
    const unknown = new TestDevice(server);
    expect((await unknown.call('POST', '/v1/account/login', { ...keys(unknown), username, sealed: sealKeyed({ password: 'synthetic-pass' }, unknown.deviceId, Buffer.alloc(8, 7)) })).body.code).toBe('INVALID_REQUEST');
    expect((await login(new TestDevice(server), username)).status, '旧客户端的第 1 版').toBe(200);
  });

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

  // 好友：owner 出示邀请，redeemer 兑换（同 social_account.e2e.test.ts）。
  const pair = async (owner: TestDevice, redeemer: TestDevice) => {
    const invite = createInviteKeys();
    expect((await owner.call('POST', '/v1/invites', { inviteId: invite.inviteId, publicKey: invite.publicKey })).status).toBe(200);
    expect((await redeemer.call('POST', '/v1/friends/redeem', { inviteId: invite.inviteId, proof: inviteProof(invite.privateKey, invite.inviteId, redeemer.deviceId), hello: helloOf() })).status).toBe(200);
  };
  const bindSocial = (account: TestDevice, social: TestDevice, takeover?: boolean) => account.call('POST', '/v1/account/social', socialBindBody(social, account.deviceId, takeover));

  it('凭恢复码重设时私信一起收回：原来的私信设备连不上中转，好友关系留着；发起重设的手机接管后好友改挂、看到换了设备', async () => {
    const username = name(), code = recoveryCode();
    const owner = new TestDevice(server);
    await register(owner, username, 'synthetic-pass', code);
    const social = new TestDevice(server);
    expect((await bindSocial(owner, social)).status).toBe(200);
    const friend = new TestDevice(server);
    expect((await friend.register()).status).toBe(200);
    await pair(friend, social);
    const fresh = new TestDevice(server);
    expect((await recover(fresh, username, code, 'new-synthetic', recoveryCode())).status).toBe(200);
    expect((await social.call('GET', '/v1/friends')).status, '被踢的手机上的私信设备连不上').toBe(401);
    const freshSocial = new TestDevice(server);
    expect((await bindSocial(fresh, freshSocial)).body.code).toBe('SOCIAL_ELSEWHERE');
    expect((await bindSocial(fresh, freshSocial, true)).body).toEqual({ deviceId: freshSocial.deviceId, moved: true });
    expect((await friend.call('GET', '/v1/friends')).body.friends).toEqual([expect.objectContaining({ deviceId: freshSocial.deviceId, movedFrom: social.deviceId })]);
  });

  it('私信本来就在发起重设的手机上：重设后重新挂上同一台就恢复，好友照旧；改密码不收回私信', async () => {
    const username = name(), code = recoveryCode();
    const owner = new TestDevice(server);
    await register(owner, username, 'synthetic-pass', code);
    const social = new TestDevice(server);
    expect((await bindSocial(owner, social)).status).toBe(200);
    const friend = new TestDevice(server);
    expect((await friend.register()).status).toBe(200);
    await pair(friend, social);
    expect((await owner.call('POST', '/v1/account/password', { sealed: seal({ password: 'changed-synthetic' }, owner.deviceId) })).status).toBe(204);
    expect((await social.call('GET', '/v1/friends')).status, '改密码不收回').toBe(200);
    expect((await recover(owner, username, code, 'new-synthetic', recoveryCode())).status).toBe(200);
    expect((await social.call('GET', '/v1/friends')).status).toBe(401);
    expect((await bindSocial(owner, social)).body).toEqual({ deviceId: social.deviceId, moved: false });
    expect((await social.call('GET', '/v1/friends')).body.friends).toEqual([expect.objectContaining({ deviceId: friend.deviceId })]);
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

  // [人工决策-2026-11-17 21:24:25] 「账号已注销」带服务器签名、绑定这次请求（见 src/modules/account/account_deleted_proof.ts）：客户端验过才清本机私信。
  it('ACCOUNT_DELETED 的回复带 proof：服务器对「设备号、这次请求的随机数」的签名，换个随机数（重放）或换台设备都验不过；别的错误不带', async () => {
    const serverKey = ed25519Key(Buffer.from(createPublicKey(createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), decodeBase64url(process.env.RELAY_FRIEND_SIGN_KEY!, 32)!]), format: 'der', type: 'pkcs8' })).export({ format: 'jwk' }).x!, 'base64url'));
    const { device: first, username } = await registered();
    const second = new TestDevice(server);
    await login(second, username);
    expect((await first.call('DELETE', '/v1/account')).status).toBe(204);
    const nonce = randomBytes(16).toString('base64url');
    const gone = await second.call('GET', '/v1/account', undefined, nonce);
    expect(gone.body.code).toBe('ACCOUNT_DELETED');
    expect(gone.status).toBe(410);
    const proof = decodeBase64url(gone.body.proof, 64)!;
    expect(verifyEd25519(serverKey, accountDeletedCanonical(second.deviceId, nonce), proof)).toBe(true);
    expect(verifyEd25519(serverKey, accountDeletedCanonical(second.deviceId, randomBytes(16).toString('base64url')), proof), '别的请求（重放）').toBe(false);
    expect(verifyEd25519(serverKey, accountDeletedCanonical(first.deviceId, nonce), proof), '别的设备').toBe(false);
    const changed = await second.call('POST', '/v1/account/password', { sealed: seal({ password: 'changed-synthetic' }, second.deviceId) });
    expect(changed.body.code).toBe('ACCOUNT_DELETED');
    expect(changed.body.proof).not.toBe(gone.body.proof);
    const stranger = new TestDevice(server);
    await stranger.register();
    const missing = await stranger.call('GET', '/v1/account');
    expect(missing.body.proof).toBeUndefined();
    expect(missing.body.code).toBe('ACCOUNT_NOT_FOUND');
    expect(accountDeletedCanonical('d', 'n').toString('utf8')).toBe('SXD1-account-deleted\nd\nn');
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

// 一个屏障：arrive() 处停住并通知 arrived，等 release 才放行。
const barrier = () => {
  let release!: () => void, reached!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve)), arrived = new Promise<void>((resolve) => (reached = resolve));
  return { arrived, release: () => release(), arrive: async () => { reached(); await gate; } };
};

// 11-28 Codex 审查 F02、F05：照审查的确定性复现写成反过来的断言（只在核对完成处、写入之前设屏障，不替换判定结果）。
describe('并发：凭据版本与注销门禁', () => {
  // 在 AccountKeys.verify 核对完 match 这份秘密后停住，等 release 才放行。
  const pauseAfterVerify = (match: (secret: string) => boolean, expected = 1) => {
    let release!: () => void, reached!: () => void, count = 0;
    const gate = new Promise<void>((resolve) => (release = resolve)), arrived = new Promise<void>((resolve) => (reached = resolve));
    const keysService = app.get(AccountKeys), original = keysService.verify.bind(keysService);
    const spy = vi.spyOn(keysService, 'verify').mockImplementation(async (secret, stored) => {
      const valid = await original(secret, stored);
      if (match(secret)) {
        if (++count === expected) reached();
        await gate;
      }
      return valid;
    });
    return { arrived, release: () => release(), restore: () => spy.mockRestore() };
  };

  it('旧密码的登录核对完还没登记时，账号凭恢复码重设了：这次登录不再登记、回用户名或密码不对', async () => {
    const owner = new TestDevice(server), stale = new TestDevice(server), recovery = new TestDevice(server);
    const username = name(), code = recoveryCode();
    expect((await register(owner, username, 'synthetic-pass', code)).status).toBe(200);
    const pause = pauseAfterVerify((secret) => secret === 'synthetic-pass');
    try {
      // 请求在调 then 时才发出。
      const pending = login(stale, username).then((response) => response);
      await pause.arrived;
      expect((await recover(recovery, username, code, 'synthetic-new-pass', recoveryCode())).status).toBe(200);
      pause.release();
      const response = await pending;
      expect(response.status).toBe(403);
      expect(response.body.code).toBe('CREDENTIALS_INVALID');
      expect((await stale.call('GET', '/v1/account')).status).toBe(404);
      expect((await recovery.call('GET', '/v1/account')).body.deviceCount).toBe(1);
    } finally {
      pause.release();
      pause.restore();
    }
  });

  it('同一份恢复码并发用两次：只有一次成功，另一次回用户名或密码不对，账号下只留成功那台', async () => {
    const owner = new TestDevice(server), first = new TestDevice(server), second = new TestDevice(server);
    const username = name(), code = recoveryCode();
    expect((await register(owner, username, 'synthetic-pass', code)).status).toBe(200);
    const pause = pauseAfterVerify((secret) => secret === code, 2);
    try {
      const pending = Promise.all([recover(first, username, code, 'synthetic-first-pass', recoveryCode()), recover(second, username, code, 'synthetic-second-pass', recoveryCode())]);
      await pause.arrived;
      pause.release();
      const responses = await pending;
      expect(responses.map((response) => response.status).sort()).toEqual([200, 403]);
      const winner = responses[0].status === 200 ? first : second, loser = winner === first ? second : first;
      expect((await winner.call('GET', '/v1/account')).body.deviceCount).toBe(1);
      expect((await loser.call('GET', '/v1/account')).status).toBe(404);
      expect((await login(new TestDevice(server), username, winner === first ? 'synthetic-first-pass' : 'synthetic-second-pass')).status).toBe(200);
    } finally {
      pause.release();
      pause.restore();
    }
  });

  // 11-28 Codex 复核 F02：改密是「查账号 → 算哈希 → 写入」，原来写入只按账号号，迟到的改密会把重设后的新密码改回去。
  it('登录着的旧设备改密码算哈希时，账号凭恢复码重设、把它踢下线了：迟到的改密回没有登录应用账号，密码仍是重设后的', async () => {
    const owner = new TestDevice(server), recovery = new TestDevice(server);
    const username = name(), code = recoveryCode();
    expect((await register(owner, username, 'synthetic-pass', code)).status).toBe(200);
    const pause = barrier();
    const keysService = app.get(AccountKeys), original = keysService.hash.bind(keysService);
    const spy = vi.spyOn(keysService, 'hash').mockImplementation(async (secret) => {
      const hashed = await original(secret);
      if (secret === 'synthetic-stale-pass') await pause.arrive();
      return hashed;
    });
    try {
      const pending = owner.call('POST', '/v1/account/password', { sealed: seal({ password: 'synthetic-stale-pass' }, owner.deviceId) }).then((response) => response);
      await pause.arrived;
      expect((await recover(recovery, username, code, 'synthetic-recovered', recoveryCode())).status).toBe(200);
      pause.release();
      const response = await pending;
      expect(response.status).toBe(404);
      expect(response.body.code).toBe('ACCOUNT_NOT_FOUND');
      expect((await login(new TestDevice(server), username, 'synthetic-stale-pass')).body.code).toBe('CREDENTIALS_INVALID');
      expect((await login(new TestDevice(server), username, 'synthetic-recovered')).status).toBe(200);
    } finally {
      pause.release();
      spy.mockRestore();
    }
  });

  it('批准方占住票据、还没登记新设备时，账号凭恢复码重设把批准方踢下线了：批准回没有登录应用账号，新设备进不了账号', async () => {
    const owner = new TestDevice(server), recovery = new TestDevice(server), fresh = new TestDevice(server);
    const username = name(), code = recoveryCode();
    expect((await register(owner, username, 'synthetic-pass', code)).status).toBe(200);
    const { ticketId, code: joinCode } = (await fresh.call('POST', '/v1/account/joins', keys(fresh))).body as { ticketId: string; code: string };
    const pause = barrier();
    const accounts = app.get(AccountRepository), original = accounts.link.bind(accounts);
    const spy = vi.spyOn(accounts, 'link').mockImplementation(async (...args) => {
      if ('approver' in args[3]) await pause.arrive();
      return original(...args);
    });
    try {
      const pending = owner.call('POST', `/v1/account/joins/${ticketId}/approve`, { code: joinCode }).then((response) => response);
      await pause.arrived;
      expect((await recover(recovery, username, code, 'synthetic-recovered', recoveryCode())).status).toBe(200);
      pause.release();
      expect((await pending).body.code).toBe('ACCOUNT_NOT_FOUND');
      expect((await fresh.call('GET', '/v1/account')).status).toBe(404);
      expect((await recovery.call('GET', '/v1/account')).body.deviceCount).toBe(1);
    } finally {
      pause.release();
      spy.mockRestore();
    }
  });

  it('反过来：旧密码的登录先登记上，之后才凭恢复码重设：重设照样把它踢下线，账号下只留重设那台', async () => {
    const owner = new TestDevice(server), stale = new TestDevice(server), recovery = new TestDevice(server);
    const username = name(), code = recoveryCode();
    expect((await register(owner, username, 'synthetic-pass', code)).status).toBe(200);
    const pause = pauseAfterVerify((secret) => secret === code);
    try {
      const recovering = recover(recovery, username, code, 'synthetic-recovered', recoveryCode()).then((response) => response);
      await pause.arrived;
      expect((await login(stale, username)).status, '重设核对完、还没写入时登录照常成功').toBe(200);
      pause.release();
      expect((await recovering).status).toBe(200);
      expect((await stale.call('GET', '/v1/account')).status).toBe(404);
      expect((await recovery.call('GET', '/v1/account')).body.deviceCount).toBe(1);
    } finally {
      pause.release();
      pause.restore();
    }
  });

  it('重设的事务中途出错（收回私信那一步失败）：整个回滚，旧密码、旧恢复码与原来的设备照旧，发起的设备没登记上', async () => {
    const owner = new TestDevice(server), recovery = new TestDevice(server);
    const username = name(), code = recoveryCode();
    expect((await register(owner, username, 'synthetic-pass', code)).status).toBe(200);
    const spy = vi.spyOn(app.get(AccountDataHooks), 'revoke').mockRejectedValueOnce(new Error('synthetic revoke failure'));
    try {
      expect((await recover(recovery, username, code, 'synthetic-recovered', recoveryCode())).status).toBe(500);
    } finally {
      spy.mockRestore();
    }
    expect((await owner.call('GET', '/v1/account')).body.deviceCount).toBe(1);
    expect((await recovery.call('GET', '/v1/account')).status).toBe(404);
    expect((await login(new TestDevice(server), username, 'synthetic-recovered')).body.code).toBe('CREDENTIALS_INVALID');
    expect((await login(new TestDevice(server), username)).status).toBe(200);
    expect((await recover(new TestDevice(server), username, code, 'synthetic-again', recoveryCode())).status, '旧恢复码还能用').toBe(200);
  });

  it('两个服务实例（同一个库与 Redis）同时用同一份恢复码：仍只有一次成功', async () => {
    const second = await createRelayApp();
    await second.listen(0, '127.0.0.1');
    try {
      const otherServer = await second.getUrl();
      const owner = new TestDevice(server), first = new TestDevice(server), other = new TestDevice(otherServer);
      const username = name(), code = recoveryCode();
      expect((await register(owner, username, 'synthetic-pass', code)).status).toBe(200);
      // 两个实例各自的 AccountKeys：都核对完再一起放行。
      let release!: () => void, count = 0, reached!: () => void;
      const gate = new Promise<void>((resolve) => (release = resolve)), arrived = new Promise<void>((resolve) => (reached = resolve));
      const spies = [app, second].map((instance) => {
        const keysService = instance.get(AccountKeys), original = keysService.verify.bind(keysService);
        return vi.spyOn(keysService, 'verify').mockImplementation(async (secret, stored) => {
          const valid = await original(secret, stored);
          if (secret === code) {
            if (++count === 2) reached();
            await gate;
          }
          return valid;
        });
      });
      try {
        const pending = Promise.all([recover(first, username, code, 'synthetic-first-pass', recoveryCode()), recover(other, username, code, 'synthetic-other-pass', recoveryCode())]);
        await arrived;
        release();
        expect((await pending).map((response) => response.status).sort()).toEqual([200, 403]);
        const [{ total }] = (await database.query('SELECT COUNT(*) AS total FROM account_device d JOIN app_account a ON a.account_id = d.account_id WHERE a.username = ?', [username])) as { total: string }[];
        expect(Number(total)).toBe(1);
      } finally {
        release();
        for (const spy of spies) spy.mockRestore();
      }
    } finally {
      await second.close();
    }
  });

  it('认领核对完、写入之前账号注销了：认领回没有登录应用账号，库里不留已注销账号的记录', async () => {
    const { device, accountId } = await registered();
    const store = app.get(DiagnosticStore), uploads = app.get(DiagnosticUploadRepository), redis = app.get<Redis>(REDIS);
    const id = 'A0D0T001', token = 'AAAAAAAAAAAAAAAAAAAAAA';
    await store.save(id, Readable.from([Buffer.alloc(100)]), (await store.reserve(100))!);
    await redis.set(RedisKeys.diagnosticClaim(id), claimHash(token), 'EX', 60);
    let release!: () => void, reached!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve)), arrived = new Promise<void>((resolve) => (reached = resolve));
    const original = uploads.claim.bind(uploads);
    const spy = vi.spyOn(uploads, 'claim').mockImplementation(async (...args) => {
      reached();
      await gate;
      return original(...args);
    });
    try {
      const pending = device.call('POST', `/v1/account/diagnostics/${id}/claim`, { claim: token }).then((response) => response);
      await arrived;
      expect((await device.call('DELETE', '/v1/account')).status).toBe(204);
      release();
      expect((await pending).body.code).toBe('ACCOUNT_NOT_FOUND');
      expect(await database.query('SELECT diagnostic_id FROM diagnostic_upload WHERE account_id = ?', [accountId])).toHaveLength(0);
    } finally {
      release();
      spy.mockRestore();
      await store.remove([id]);
      await uploads.forget([id]);
    }
  });

  // 注销（或闲置清理）正停在给账号行加排他锁那一句、等别的事务的共享锁：同一个数据库用户看得到自己的连接正在执行什么（不用 PROCESS 权限）。
  const lockWaiting = async (pattern: string) => {
    for (let attempt = 0; attempt < 300; attempt++) {
      const rows = (await database.query('SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE ?', [pattern])) as unknown[];
      if (rows.length > 0) return true;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    return false;
  };
  const accountLockPattern = 'SELECT account_id FROM app_account WHERE account_id IN (%) FOR UPDATE';
  const settled = <T>(promise: Promise<T>) => {
    const state = { done: false };
    void promise.then(() => (state.done = true), () => (state.done = true));
    return state;
  };

  it('写入门禁按账号行串行：写事务拿着共享锁时，注销停在锁账号行那一句等它（看得到在等、还没回）；写入提交后注销连它写的一起删；之后的写入过不了门禁', async () => {
    const { device, accountId } = await registered();
    const accounts = app.get(AccountRepository);
    const pause = barrier();
    const writing = database.transaction(async (manager) => {
      await accounts.hold(manager, accountId);
      await pause.arrive();
      await manager.query('INSERT INTO diagnostic_upload (diagnostic_id, account_id, bytes, create_time, update_time) VALUES (?, ?, 1, NOW(), NOW())', ['A0D0T002', accountId]);
    });
    await pause.arrived;
    const deleting = device.call('DELETE', '/v1/account').then((response) => response);
    const state = settled(deleting);
    expect(await lockWaiting(accountLockPattern), '注销在等账号行的锁').toBe(true);
    expect(state.done, '写入没提交之前注销回不来').toBe(false);
    pause.release();
    await writing;
    expect((await deleting).status).toBe(204);
    expect(await database.query('SELECT diagnostic_id FROM diagnostic_upload WHERE account_id = ?', [accountId])).toHaveLength(0);
    await expect(database.transaction((manager) => accounts.hold(manager, accountId))).rejects.toMatchObject({ code: 'ACCOUNT_NOT_FOUND' });
  });

  it('400 天不活跃的清理同样按账号行等在途写入：写入提交后连它写的一起删', async () => {
    const { device, accountId } = await registered();
    await database.query('UPDATE app_account SET last_seen_time = ? WHERE account_id = ?', [new Date(Date.now() - 401 * 86400_000), accountId]);
    const accounts = app.get(AccountRepository);
    const pause = barrier();
    const writing = database.transaction(async (manager) => {
      await accounts.hold(manager, accountId);
      await pause.arrive();
      await manager.query('INSERT INTO diagnostic_upload (diagnostic_id, account_id, bytes, create_time, update_time) VALUES (?, ?, 1, NOW(), NOW())', ['A0D0T003', accountId]);
    });
    await pause.arrived;
    const sweeping = app.get(AccountRetentionTask).sweep();
    const state = settled(sweeping);
    expect(await lockWaiting(accountLockPattern)).toBe(true);
    expect(state.done).toBe(false);
    pause.release();
    await writing;
    await sweeping;
    expect((await device.call('GET', '/v1/account')).status).toBe(404);
    expect(await database.query('SELECT diagnostic_id FROM diagnostic_upload WHERE account_id = ?', [accountId])).toHaveLength(0);
  });

  it('注销提交之后才到的写入：挑战开局、解锁购买与抽中、时长券、诊断包认领一律过不了门禁，整个事务回滚、什么也不留', async () => {
    const { device, accountId } = await registered();
    expect((await device.call('DELETE', '/v1/account')).status).toBe(204);
    const hold = app.get(AccountRepository).hold, now = new Date();
    const charged: string[] = [];
    const attempts: [string, () => Promise<unknown>][] = [
      ['challenge', () => app.get(ChallengeRepository).insertRun({ runId: 'synthetic-run-0001', accountId, challengeId: 'synthetic', active: true, deadline: now, plan: '{}', progress: '{}', ending: null, points: null, awarded: null, endTime: null }, now, hold, async () => void charged.push('challenge'))],
      ['unlock buy', () => app.get(UnlockRepository).buy(accountId, 'game.synthetic', 10, now, hold, async () => void charged.push('unlock'))],
      ['unlock drawn', () => app.get(UnlockRepository).insertDrawn(accountId, ['game.synthetic'], now, hold)],
      ['pass', () => app.get(PassRepository).extend(accountId, 'toolbox.synthetic', 10, 1, now, hold, async () => void charged.push('pass'))],
      ['diagnostic', () => app.get(DiagnosticUploadRepository).claim('A0D0T004', accountId, 1, now, hold)],
    ];
    for (const [label, attempt] of attempts) await expect(attempt(), label).rejects.toMatchObject({ code: 'ACCOUNT_NOT_FOUND' });
    expect(charged, '门禁先于扣积分').toEqual([]);
    for (const table of ['challenge_run', 'account_unlock', 'account_pass', 'diagnostic_upload', 'points_entry']) {
      expect(await database.query(`SELECT id FROM ${table} WHERE account_id = ?`, [accountId]), table).toHaveLength(0);
    }
  });

  it('挂私信的请求核对完账号、写入之前账号注销了：回没有登录应用账号，不留挂接、不登记那台私信设备', async () => {
    const { device } = await registered();
    const social = new TestDevice(server);
    const accounts = app.get(AccountRepository), original = accounts.accountOf.bind(accounts);
    const pause = barrier();
    let calls = 0;
    const spy = vi.spyOn(accounts, 'accountOf').mockImplementation(async (deviceId) => {
      const result = await original(deviceId);
      // 第一次是按发请求的账号密钥认账号，之后停住。
      if (++calls === 1) await pause.arrive();
      return result;
    });
    try {
      const pending = device.call('POST', '/v1/account/social', socialBindBody(social, device.deviceId)).then((response) => response);
      await pause.arrived;
      spy.mockImplementation(original);
      expect((await device.call('DELETE', '/v1/account')).status).toBe(204);
      pause.release();
      expect((await pending).body.code).toBe('ACCOUNT_NOT_FOUND');
      expect(await database.query('SELECT id FROM account_social WHERE device_id = ?', [social.deviceId])).toHaveLength(0);
      expect(await database.query('SELECT device_id FROM device WHERE device_id = ?', [social.deviceId])).toHaveLength(0);
    } finally {
      pause.release();
      spy.mockRestore();
    }
  });

  it('注销的事务回滚时诊断包文件还在、认领记录也在；提交之后才删文件', async () => {
    const { device, accountId } = await registered();
    const store = app.get(DiagnosticStore), redis = app.get<Redis>(REDIS);
    // 每次一个新编号（中途失败留下的记录不挡下一次）。
    const id = newDiagnosticId(), token = 'AAAAAAAAAAAAAAAAAAAAAA';
    await store.save(id, Readable.from([Buffer.alloc(100)]), (await store.reserve(100))!);
    await redis.set(RedisKeys.diagnosticClaim(id), claimHash(token), 'EX', 60);
    try {
      expect((await device.call('POST', `/v1/account/diagnostics/${id}/claim`, { claim: token })).status).toBe(200);
      const file = join(env().diagnosticsDir, id);
      const hooks = app.get(AccountDataHooks), original = hooks.run.bind(hooks);
      // 各模块的删除都做完了（诊断包那一步已删记录），事务提交前出错。
      const spy = vi.spyOn(hooks, 'run').mockImplementationOnce(async (...args) => {
        await original(...args);
        throw new Error('synthetic failure after hooks');
      });
      try {
        expect((await device.call('DELETE', '/v1/account')).status).toBe(500);
      } finally {
        spy.mockRestore();
      }
      expect(existsSync(file), '回滚后文件还在').toBe(true);
      expect(await database.query('SELECT diagnostic_id FROM diagnostic_upload WHERE account_id = ?', [accountId])).toHaveLength(1);
      expect((await device.call('DELETE', '/v1/account')).status).toBe(204);
      expect(existsSync(file), '提交后删了文件').toBe(false);
      expect(await database.query('SELECT diagnostic_id FROM diagnostic_upload WHERE account_id = ?', [accountId])).toHaveLength(0);
    } finally {
      await store.remove([id]);
      await app.get(DiagnosticUploadRepository).forget([id]);
    }
  });
});
