import { createCipheriv, createHash, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createServer, IncomingMessage, Server, ServerResponse } from 'node:http';
import { AddressInfo } from 'node:net';
import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { DataSource } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { REDIS } from 'src/common/redis/redis.module';
import { accountDeviceLimit, accountSignInPerSubjectPerDay } from 'src/common/relay_limits';
import { decodeBase64url } from 'src/common/crypto/relay_crypto';
import { openAccountSeal, x25519PrivateKey, x25519PublicOf } from 'src/modules/account/account_keys';
import { AccountRetentionTask } from 'src/modules/account/account_retention.task';
import { buildLoginPlain, encryptLoginParams, hexMd5, KingoCredential, loginToken } from 'src/modules/kingo/kingo_codec';
import { TestDevice } from './test_device';

// 假教务：按客户端 KingoClient 走的那几个地址应答。每个学号一种情形：正常、要验证码、锁定；登录参数按教务的算法核对（只认对的口令摘要与验证码）。
const pageSession = 'PAGESESSION01';
const deskey = 'tempDesKey9';
const timestamp = '2026-11-13 22:00:00';
const captchaAnswer = 'AB12';
const wrongCaptcha = 'ZZZZ';
type Student = { password: string; mode: 'normal' | 'captcha' | 'locked' };
const students = new Map<string, Student>();
const signedIn = new Map<string, string>();
let throttled = false;
let kingo: Server;

const credentialOf = (account: string, password: string): KingoCredential => ({
  account,
  passwordDigest: hexMd5(password),
  expression: '5',
  length: String(password.length),
  userzh: password.toLowerCase().includes(account.toLowerCase()) ? '1' : '0',
  policy: password.length < 6 || password === account ? '0' : '1',
});

const readBody = (request: IncomingMessage) => new Promise<string>((resolve) => {
  let body = '';
  request.on('data', (chunk: Buffer) => (body += chunk.toString('utf8')));
  request.on('end', () => resolve(body));
});

const fakeKingo = async (request: IncomingMessage, response: ServerResponse) => {
  const url = new URL(request.url ?? '/', 'http://kingo.test');
  const session = /JSESSIONID=([^;]+)/.exec(request.headers.cookie ?? '')?.[1] ?? '';
  const send = (status: number, body: string | Buffer, headers: Record<string, string> = {}) => {
    response.writeHead(status, { 'content-type': 'text/html; charset=utf-8', ...headers });
    response.end(body);
  };
  if (throttled) return send(302, '', { location: '/frame/errors/406.jsp' });
  if (url.pathname === '/cas/login.action') return send(200, `<script>var _ssessionid = "${pageSession}";</script>`, { 'set-cookie': `JSESSIONID=${randomBytes(8).toString('hex')}; Path=/` });
  if (url.pathname.startsWith('/custom/js/')) return send(200, '');
  if (url.pathname === '/frame/homepage') return send(200, url.searchParams.get('method') === 'getTempDeskey' ? deskey : timestamp);
  if (url.pathname === '/cas/genValidateCode') return send(200, Buffer.from([0xff, 0xd8, 0xff, 0xd9]), { 'content-type': 'image/jpeg' });
  if (url.pathname === '/cas/logon.action') {
    const form = await readBody(request);
    const params = /params=([^&]*)/.exec(form)?.[1] ?? '';
    const json = (value: unknown) => send(200, JSON.stringify(value), { 'content-type': 'application/json;charset=UTF-8' });
    for (const [account, student] of students) {
      // 假教务解不开 DES，只能按几种候选验证码各算一遍去比；ZZZZ 是用例里的错答。
      for (const captcha of ['', captchaAnswer, wrongCaptcha]) {
        const plain = buildLoginPlain(credentialOf(account, student.password), pageSession, captcha);
        if (encryptLoginParams(plain, deskey) !== params || !form.includes(`token=${loginToken(plain, timestamp)}`)) continue;
        if (student.mode === 'locked') return json({ status: '402', message: '您的账号已被锁定' });
        if (student.mode === 'captcha' && captcha !== captchaAnswer) return json({ status: '401', message: '验证码错误' });
        signedIn.set(session, account);
        return json({ status: '200', message: '操作成功!', result: '/frame/homes.action?v=1' });
      }
    }
    return json({ status: '402', message: '账号或密码有误!' });
  }
  if (url.pathname === '/frame/homes.action') return send(200, '<html></html>');
  if (url.pathname === '/frame/home/js/SetMainInfo.jsp') {
    const account = signedIn.get(session);
    return send(200, account === undefined ? "var G_USER_CODE = 'kingo.guest';" : `var G_USER_CODE = 'U${account}'; var _loginid = '${account}'; var _currentXn = '2026'; var _currentXq = '0';`);
  }
  return send(404, '');
};

// 测试里的客户端封装（同 lib/social/account_seal.dart），中转公钥由测试私钥推出。
const testSealPrivate = x25519PrivateKey(decodeBase64url(process.env.RELAY_ACCOUNT_SEAL_KEY!, 32)!);
const testSealPublic = x25519PublicOf(testSealPrivate);
const x25519SpkiPrefix = Buffer.from('302a300506032b656e032100', 'hex');
const seal = (credential: KingoCredential | Record<string, string>, deviceId: string) => {
  const ephemeral = generateKeyPairSync('x25519');
  const ephemeralPublic = Buffer.from(ephemeral.publicKey.export({ format: 'jwk' }).x!, 'base64url');
  const shared = diffieHellman({ privateKey: ephemeral.privateKey, publicKey: createPublicKey({ key: Buffer.concat([x25519SpkiPrefix, testSealPublic]), format: 'der', type: 'spki' }) });
  const key = Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeralPublic, testSealPublic]), 'SXD1-account-sign-in', 32));
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.concat([Buffer.from([1]), ephemeralPublic, Buffer.from(deviceId, 'utf8')]));
  const body = Buffer.concat([cipher.update(JSON.stringify(credential), 'utf8'), cipher.final()]);
  return Buffer.concat([Buffer.from([1]), ephemeralPublic, nonce, body, cipher.getAuthTag()]).toString('base64url');
};

let app: NestExpressApplication;
let server: string;
let database: DataSource;
let serial = 0;

// 每个用例的学号各不相同（按学号的尝试次数一天只清不掉，Redis 每个用例前清空）。
const student = (mode: Student['mode'] = 'normal') => {
  const account = `2026${String(Date.now() % 1e6).padStart(6, '0')}${serial++}`;
  students.set(account, { password: `pw-${account}`, mode });
  return { account, password: `pw-${account}` };
};

const signIn = (device: TestDevice, credential: KingoCredential | Record<string, string>, extra: Record<string, string> = {}, sealedFor = device.deviceId) =>
  device.call('POST', '/v1/account/sign-in/kingo', { signPublicKey: device.signPublicKey, boxPublicKey: device.boxPublicKey, sealed: seal(credential, sealedFor), ...extra });

beforeAll(async () => {
  kingo = createServer((request, response) => {
    fakeKingo(request, response).catch((error) => console.error(error));
  });
  await new Promise<void>((resolve) => kingo.listen(0, '127.0.0.1', resolve));
  process.env.RELAY_KINGO_BASE = `http://127.0.0.1:${(kingo.address() as AddressInfo).port}`;
  app = await createRelayApp();
  await app.listen(0, '127.0.0.1');
  server = await app.getUrl();
  database = app.get(DataSource);
});

beforeEach(async () => {
  throttled = false;
  await app.get<Redis>(REDIS).flushdb();
});

afterAll(async () => {
  await app.close();
  await new Promise<void>((resolve) => kingo.close(() => resolve()));
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

describe('应用账号', () => {
  it('教务登录：第一次新建账号，同一学号换一把设备密钥登录到同一个账号', async () => {
    const { account, password } = student();
    const first = new TestDevice(server);
    const signed = await signIn(first, credentialOf(account, password));
    expect(signed.status).toBe(200);
    expect(signed.body).toMatchObject({ status: 'signedIn', captcha: null, account: { created: true } });
    const accountId = signed.body.account.accountId as string;
    expect(accountId).toMatch(/^[A-Za-z0-9_-]{22}$/);
    const second = new TestDevice(server);
    const again = await signIn(second, credentialOf(account, password));
    expect(again.body.account).toMatchObject({ accountId, created: false });
    const summary = await first.call('GET', '/v1/account');
    expect(summary.status).toBe(200);
    expect(summary.body).toMatchObject({ accountId, providers: ['kingo'], deviceCount: 2 });
    // 库里只有学号的 HMAC，没有学号本身。
    const rows = (await database.query('SELECT subject_hash AS subjectHash FROM account_identity WHERE account_id = ?', [accountId])) as { subjectHash: string }[];
    expect(rows).toHaveLength(1);
    expect(rows[0].subjectHash).not.toContain(account);
    expect(rows[0].subjectHash).not.toBe(createHash('sha256').update(account).digest('base64url'));
  });

  it('密码错：教务拒绝，设备密钥不登记', async () => {
    const { account } = student();
    const device = new TestDevice(server);
    const response = await signIn(device, credentialOf(account, 'wrong-password'));
    expect(response.status).toBe(422);
    expect(response.body).toMatchObject({ code: 'ACCOUNT_REJECTED', reason: 'passwordWrong' });
    expect((await device.call('GET', '/v1/account')).body.code).toBe('UNAUTHORIZED');
  });

  it('锁定的账号原样报给客户端', async () => {
    const { account, password } = student('locked');
    const response = await signIn(new TestDevice(server), credentialOf(account, password));
    expect(response.body).toMatchObject({ code: 'ACCOUNT_REJECTED', reason: 'accountLocked', message: '您的账号已被锁定' });
  });

  it('要验证码：给图与挑战号，答对后登录；挑战号用过、换设备都不认', async () => {
    const { account, password } = student('captcha');
    const device = new TestDevice(server);
    const first = await signIn(device, credentialOf(account, password));
    expect(first.body).toMatchObject({ status: 'captcha', account: null, captcha: { contentType: 'image/jpeg', hint: '请输入图中的验证码', image: Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString('base64') } });
    const challengeId = first.body.captcha.challengeId as string;
    const stranger = new TestDevice(server);
    expect((await signIn(stranger, credentialOf(account, password), { challengeId, captcha: captchaAnswer })).body.code).toBe('CAPTCHA_EXPIRED');
    const retry = await signIn(device, credentialOf(account, password));
    const answered = await signIn(device, credentialOf(account, password), { challengeId: retry.body.captcha.challengeId, captcha: captchaAnswer });
    expect(answered.body).toMatchObject({ status: 'signedIn', account: { created: true } });
    expect((await signIn(device, credentialOf(account, password), { challengeId: retry.body.captcha.challengeId, captcha: captchaAnswer })).body.code).toBe('CAPTCHA_EXPIRED');
  });

  it('验证码答错再给一张新图', async () => {
    const { account, password } = student('captcha');
    const device = new TestDevice(server);
    const first = await signIn(device, credentialOf(account, password));
    const wrong = await signIn(device, credentialOf(account, password), { challengeId: first.body.captcha.challengeId, captcha: wrongCaptcha });
    expect(wrong.body).toMatchObject({ status: 'captcha', captcha: { hint: '验证码不正确，请重新输入' } });
    expect(wrong.body.captcha.challengeId).not.toBe(first.body.captcha.challengeId);
  });

  it('封给别的设备、内容不全或解不开的登录信息一律不认', async () => {
    const { account, password } = student();
    const device = new TestDevice(server);
    expect((await signIn(device, credentialOf(account, password), {}, 'CCCCCCCCCCCCCCCCCCCCCC')).body.code).toBe('INVALID_REQUEST');
    const { policy: _, ...partial } = credentialOf(account, password);
    expect((await signIn(device, partial)).body.code).toBe('INVALID_REQUEST');
    expect((await signIn(device, { ...credentialOf(account, password), extra: '1' })).body.code).toBe('INVALID_REQUEST');
    expect((await signIn(device, { ...credentialOf(account, password), passwordDigest: 'NOT-HEX' })).body.code).toBe('INVALID_REQUEST');
    const raw = await device.call('POST', '/v1/account/sign-in/kingo', { signPublicKey: device.signPublicKey, boxPublicKey: device.boxPublicKey, sealed: 'short' });
    expect(raw.status).toBe(400);
    const unknown = await device.call('POST', '/v1/account/sign-in/phone', { signPublicKey: device.signPublicKey, boxPublicKey: device.boxPublicKey, sealed: seal(credentialOf(account, password), device.deviceId) });
    expect(unknown.body.code).toBe('INVALID_REQUEST');
  });

  it('同一学号每天的尝试次数有上限（防被拿来试密码）', async () => {
    const { account } = student();
    for (let index = 0; index < accountSignInPerSubjectPerDay; index++) {
      expect((await signIn(new TestDevice(server), credentialOf(account, `guess-${index}`))).body.code).toBe('ACCOUNT_REJECTED');
    }
    const blocked = await signIn(new TestDevice(server), credentialOf(account, 'guess-last'));
    expect(blocked.status).toBe(429);
    expect(blocked.body.code).toBe('RATE_LIMITED');
  });

  it('教务限流或连不上时报 UPSTREAM_UNAVAILABLE', async () => {
    const { account, password } = student();
    throttled = true;
    const response = await signIn(new TestDevice(server), credentialOf(account, password));
    expect(response.body).toMatchObject({ code: 'UPSTREAM_UNAVAILABLE', reason: 'rateLimited' });
  });

  it('退出账号就是删设备密钥：登记连带删除，另一台照常', async () => {
    const { account, password } = student();
    const first = new TestDevice(server);
    const second = new TestDevice(server);
    await signIn(first, credentialOf(account, password));
    await signIn(second, credentialOf(account, password));
    expect((await first.call('DELETE', '/v1/devices')).status).toBe(204);
    expect((await first.call('GET', '/v1/account')).body.code).toBe('UNAUTHORIZED');
    expect((await second.call('GET', '/v1/account')).body.deviceCount).toBe(1);
  });

  it('注销账号：别的设备密钥也不再属于它，再登录建新账号', async () => {
    const { account, password } = student();
    const first = new TestDevice(server);
    const second = new TestDevice(server);
    const original = (await signIn(first, credentialOf(account, password))).body.account.accountId as string;
    await signIn(second, credentialOf(account, password));
    expect((await first.call('DELETE', '/v1/account')).status).toBe(204);
    expect((await second.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
    expect((await first.call('DELETE', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
    const fresh = await signIn(second, credentialOf(account, password));
    expect(fresh.body.account.created).toBe(true);
    expect(fresh.body.account.accountId).not.toBe(original);
  });

  it(`一个账号最多 ${accountDeviceLimit} 把设备密钥，再登录顶掉最久没用的`, async () => {
    const { account, password } = student();
    const devices: TestDevice[] = [];
    for (let index = 0; index <= accountDeviceLimit; index++) {
      // 按学号每天 10 次：每 9 次清一下 Redis 里的计数。
      if (index % 9 === 0) await app.get<Redis>(REDIS).flushdb();
      const device = new TestDevice(server);
      expect((await signIn(device, credentialOf(account, password))).body.status).toBe('signedIn');
      devices.push(device);
    }
    expect((await devices[accountDeviceLimit].call('GET', '/v1/account')).body.deviceCount).toBe(accountDeviceLimit);
    expect((await devices[0].call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
  });

  it('400 天没登录也没查看的账号由清理任务删除', async () => {
    const { account, password } = student();
    const device = new TestDevice(server);
    const accountId = (await signIn(device, credentialOf(account, password))).body.account.accountId as string;
    await database.query('UPDATE app_account SET last_seen_time = ? WHERE account_id = ?', [new Date(Date.now() - 401 * 86400_000), accountId]);
    await app.get(AccountRetentionTask).sweep();
    expect((await device.call('GET', '/v1/account')).body.code).toBe('ACCOUNT_NOT_FOUND');
    expect(await database.query('SELECT id FROM account_identity WHERE account_id = ?', [accountId])).toHaveLength(0);
  });
});
