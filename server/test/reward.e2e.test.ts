import { createDecipheriv, createHash, createPrivateKey, createPublicKey, diffieHellman, hkdfSync, randomBytes } from 'node:crypto';
import { NestExpressApplication } from '@nestjs/platform-express';
import Redis from 'ioredis';
import { createConnection, Connection } from 'mysql2/promise';
import { mkdir, readFile, rm, utimes, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { PassThrough } from 'node:stream';
import request from 'supertest';
import { DataSource, EntityManager } from 'typeorm';

import { createRelayApp } from 'src/relay_app';
import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { decodeBase64url, ed25519Key, rewardPrizeCanonical, verifyEd25519, x25519PublicKey } from 'src/common/crypto/relay_crypto';
import { rewardDrawPerDevicePerHour, rewardDrawPerHour, rewardKeepDays } from 'src/common/relay_limits';
import { RewardAdminError, runRewardAdmin } from 'src/modules/reward/reward_admin';
import { RewardRetentionTask } from 'src/modules/reward/reward_retention.task';
import { RewardDice } from 'src/modules/reward/reward.service';
import { rewardChance, rewardLevelWeight, rewardPickTier, rewardReleased, rewardWeight } from 'src/modules/reward/reward_odds';
import { insertAccount } from './account_fixture';
import { TestDevice } from './test_device';

let app: NestExpressApplication;
let server: string;
let database: DataSource;
let admin: Connection;
let roll: ReturnType<typeof vi.spyOn>;

const hour = 3600_000;

// 活动编号每个用例各取一个：活动行在服务端缓存 60 秒，同一编号在用例之间改设置不会立即生效。
let serial = 0;
const campaignKey = () => `test-${Date.now().toString(36)}-${serial++}`;

const lines = (text: string) =>
  async function* () {
    for (const line of text.split('\n')) yield line;
  };

// 经维护命令建活动、导入奖品（同维护者在服务器上的用法）。
const setup = async (options: { from?: number; to?: number; mode?: 'uniform' | 'weighted'; chance?: number; maxWeight?: number; prizes?: number; bigPrizes?: number } = {}) => {
  const key = campaignKey();
  const now = Date.now();
  const args = ['create', key, '--from', new Date(now + (options.from ?? -hour / 2)).toISOString(), '--to', new Date(now + (options.to ?? hour / 2)).toISOString(), '--mode', options.mode ?? 'uniform', '--chance', String(options.chance ?? 0.2)];
  if (options.mode === 'weighted') args.push('--max-weight', String(options.maxWeight ?? 3));
  await runRewardAdmin(admin, args, lines(''));
  const prizes = options.prizes ?? 3;
  if (prizes > 0) await runRewardAdmin(admin, ['import', key], lines(Array.from({ length: prizes }, (_, index) => `口令\t口令${index}\t附言${index}`).join('\n')));
  if ((options.bigPrizes ?? 0) > 0) await runRewardAdmin(admin, ['import', key, '--tier', '1'], lines(Array.from({ length: options.bigPrizes! }, (_, index) => `口令\t大额${index}`).join('\n')));
  return key;
};

// 抽签人：登录了应用账号的设备。注册设备后直接在库里登记账号（账号登录本身在 account.e2e.test.ts 测）；
// 注册接口同一来源每小时 20 台新设备，每个用例前清空限流。accountId 给了已有的就是同一个账号的另一台设备（同一个人）。
// created 是账号建立的时刻：默认 8 天前（满 7 天才能抽，人工决策见 reward_odds.ts）。
const registered = async (accountId = randomBytes(16).toString('base64url'), created = new Date(Date.now() - 8 * 86400_000)) => {
  const device = new TestDevice(server);
  expect((await device.register()).status).toBe(200);
  const now = new Date();
  if ((await database.query('SELECT id FROM app_account WHERE account_id = ?', [accountId])).length === 0) await insertAccount(database, accountId, now, created);
  await database.query('INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?)', [accountId, device.deviceId, now, now]);
  return device;
};

const draw = (device: TestDevice, key: string, body: Record<string, unknown>) => device.call('POST', `/v1/rewards/${key}/draw`, body);

// 服务器在线签名钥的公钥（测试钥，同 setup_env.ts 的 RELAY_FRIEND_SIGN_KEY）：第 2 版奖品信封用它验签（同客户端 relayServerKeys）。
const serverPublic = () =>
  ed25519Key(Buffer.from(createPublicKey(createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), decodeBase64url(process.env.RELAY_FRIEND_SIGN_KEY!, 32)!]), format: 'der', type: 'pkcs8' })).export({ format: 'jwk' }).x!, 'base64url'));

// 解开奖品信封（同客户端 openRewardPrize，布局见 src/modules/reward/reward_seal.ts）：只有抽签设备的加密私钥打得开，打不开抛错；
// 第 2 版先按服务器签名验过（绑定活动与设备）再解，验不过抛错。
const prizeOf = (device: TestDevice, key: string, body: { result: string; sealed: string | null }) => {
  if (body.sealed === null) return null;
  let sealed = Buffer.from(body.sealed, 'base64url');
  if (sealed[0] === 2) {
    const signature = sealed.subarray(sealed.length - 64);
    sealed = sealed.subarray(0, sealed.length - 64);
    if (!verifyEd25519(serverPublic(), rewardPrizeCanonical(key, device.deviceId, sealed), signature)) throw new Error('奖品信封的服务器签名不对');
  }
  const ephemeral = sealed.subarray(1, 33), devicePublic = Buffer.from(device.boxPublicKey, 'base64url');
  const shared = diffieHellman({ privateKey: device.boxPrivate, publicKey: x25519PublicKey(ephemeral) });
  const decipher = createDecipheriv('aes-256-gcm', Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeral, devicePublic]), 'SXD1-reward-prize', 32)), sealed.subarray(33, 45));
  decipher.setAAD(Buffer.concat([sealed.subarray(0, 1), ephemeral, Buffer.from(`${key}\n${device.deviceId}`, 'utf8')]));
  decipher.setAuthTag(sealed.subarray(sealed.length - 16));
  return JSON.parse(Buffer.concat([decipher.update(sealed.subarray(45, sealed.length - 16)), decipher.final()]).toString('utf8')) as { kind: string; content: string; note: string };
};

// 给设备所在账号记一笔积分（等级按近 12 个月获得的总数算），门槛写进灰度配置。
const levels = [0, 500, 3000, 10000, 30000, 80000];
const earn = async (device: TestDevice, amount: number) => {
  const [{ accountId }] = (await database.query('SELECT account_id AS accountId FROM account_device WHERE device_id = ?', [device.deviceId])) as { accountId: string }[];
  const now = new Date();
  await database.query('INSERT INTO points_grant (account_id, amount, remaining, source, source_key, expire_time, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', [
    accountId,
    amount,
    amount,
    'challenge',
    randomBytes(8).toString('hex'),
    new Date(now.getTime() + 300 * 86400_000),
    now,
    now,
  ]);
};
const rolloutFile = () => join(env().releasesDir, 'rollout.json');

// 库里的抽签人：登录身份的 sha256（同 reward.service.ts）。
const participantHash = (accountId: string) => createHash('sha256').update(`SXD1-reward\naccount\n${accountId}`).digest('hex');

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
  roll = vi.spyOn(app.get(RewardDice), 'roll');
});

afterEach(() => {
  vi.restoreAllMocks();
});

afterAll(async () => {
  await admin.end();
  await app.close();
});

describe('概率模型', () => {
  it('平权人人一样；加权从 1 线性到上限，20 天封顶；概率不超过 1', () => {
    expect(rewardWeight('uniform', 30, 0, 3)).toBe(1);
    expect(rewardWeight('weighted', 0, 0, 3)).toBe(1);
    expect(rewardWeight('weighted', 10, 0, 3)).toBe(2);
    expect(rewardWeight('weighted', 20, 0, 3)).toBe(3);
    expect(rewardWeight('weighted', 30, 0, 3)).toBe(3);
    expect(rewardChance(0.2, 3)).toBeCloseTo(0.6);
    expect(rewardChance(0.5, 3)).toBe(1);
  });

  it('积分等级并进加权：取活跃天数与等级里高的倍数，上限仍是活动的；平权时等级不起作用', () => {
    expect(rewardLevelWeight('weighted', 5, 3)).toBe(3);
    expect(rewardLevelWeight('weighted', 1, 3)).toBeCloseTo(1.4);
    expect(rewardLevelWeight('weighted', 5, 2)).toBe(2);
    expect(rewardLevelWeight('uniform', 5, 3)).toBe(1);
    expect(rewardWeight('weighted', 0, 5, 3)).toBe(3);
    expect(rewardWeight('weighted', 10, 1, 3)).toBe(2);
    expect(rewardWeight('weighted', 2, 3, 3)).toBeCloseTo(2.2);
    expect(rewardWeight('uniform', 0, 5, 3)).toBe(1);
  });

  it('挑档：按可发份数，大额档再乘等级倍数；都发不了为空', () => {
    const available = [{ tier: 0, count: 4 }, { tier: 1, count: 1 }];
    expect(rewardPickTier(available, 1, 0.7)).toBe(0);
    expect(rewardPickTier(available, 3, 0.7)).toBe(1);
    expect(rewardPickTier(available, 3, 0.5)).toBe(0);
    expect(rewardPickTier([{ tier: 0, count: 0 }, { tier: 1, count: 2 }], 1, 0)).toBe(1);
    expect(rewardPickTier([{ tier: 0, count: 0 }], 3, 0.5)).toBeNull();
    // 按模型抽很多次：Lv5（3 倍）时大额档占 3/7。
    const dice = new RewardDice();
    const big = Array.from({ length: 20000 }, () => rewardPickTier(available, 3, dice.roll())).filter((tier) => tier === 1).length / 20000;
    expect(big).toBeCloseTo(3 / 7, 1);
  });

  it('均匀放量：24 小时 24 份每小时累计多放 1 份，最后一小时放完；时长不足一小时也能放完', () => {
    const start = new Date('2027-02-06T00:00:00Z'), end = new Date('2027-02-07T00:00:00Z');
    expect(rewardReleased(24, start, end, new Date(start.getTime() + 10 * 60_000))).toBe(1);
    expect(rewardReleased(24, start, end, new Date(start.getTime() + 5.5 * hour))).toBe(6);
    expect(rewardReleased(24, start, end, new Date(end.getTime() - 1))).toBe(24);
    expect(rewardReleased(5, start, new Date(start.getTime() + 20 * 60_000), new Date(start.getTime() + 60_000))).toBe(5);
    expect(rewardReleased(10, start, end, new Date(start.getTime() + 30 * 60_000))).toBe(1);
  });

  // 按模型的概率抽很多次，抽中率落在期望附近（不经数据库，验概率本身没写反）。
  it('抽中率与模型一致：平权 0.2；加权新用户 0.2、最活跃 0.6', () => {
    const dice = new RewardDice();
    const rate = (chance: number) => Array.from({ length: 20000 }, () => dice.roll() < chance).filter(Boolean).length / 20000;
    expect(rate(rewardChance(0.2, rewardWeight('uniform', 25, 0, 3)))).toBeCloseTo(0.2, 1);
    expect(rate(rewardChance(0.2, rewardWeight('weighted', 0, 0, 3)))).toBeCloseTo(0.2, 1);
    expect(rate(rewardChance(0.2, rewardWeight('weighted', 25, 0, 3)))).toBeCloseTo(0.6, 1);
  });
});

describe('抽奖', () => {
  it('要求登录了应用账号的设备签名：不签名、没登记、签名不对回 UNAUTHORIZED，没登录应用账号回 ACCOUNT_NOT_FOUND，都不掷骰子', async () => {
    const key = await setup();
    const unsigned = await request(server).post(`/v1/rewards/${key}/draw`).send({ activeDays: 3 });
    expect(unsigned.status).toBe(401);
    expect(unsigned.body.code).toBe('UNAUTHORIZED');
    // 旧客户端的免签名请求同样不收。
    expect((await request(server).post(`/v1/rewards/${key}/draw`).send({ participant: 'AAAAAAAAAAAAAAAAAAAAAA', activeDays: 3 })).status).toBe(401);
    const stranger = new TestDevice(server);
    const unknown = await draw(stranger, key, { activeDays: 3 });
    expect(unknown.status).toBe(401);
    expect(unknown.body.code).toBe('UNAUTHORIZED');
    const device = await registered(), other = await registered();
    const path = `/v1/rewards/${key}/draw`, body = Buffer.from(JSON.stringify({ activeDays: 3 }));
    const forged = await request(server).post(path).set({ ...other.headers('POST', path, body), 'x-sxd-device': device.deviceId }).send(body.toString());
    expect(forged.status).toBe(401);
    const bare = new TestDevice(server);
    expect((await bare.register()).status).toBe(200);
    const anonymous = await draw(bare, key, { activeDays: 3 });
    expect(anonymous.status).toBe(404);
    expect(anonymous.body.code).toBe('ACCOUNT_NOT_FOUND');
    expect(roll).not.toHaveBeenCalled();
  });

  // 11-15 16:40 起按账号认人（自己的账号体系没有能跨账号认人的身份，见 reward_odds.ts）：注销后重新注册就是新的人。
  it('一个账号一次活动只抽一次：同一账号换一台设备还是第一次的结果；换个账号才重新掷', async () => {
    const key = await setup();
    const accountId = randomBytes(16).toString('base64url');
    roll.mockReturnValue(0.99);
    expect((await draw(await registered(accountId), key, { activeDays: 3 })).body.result).toBe('missed');
    roll.mockReturnValue(0);
    expect((await draw(await registered(accountId), key, { activeDays: 3 })).body.result).toBe('missed');
    expect((await draw(await registered(), key, { activeDays: 3 })).body.result).toBe('won');
    expect(roll).toHaveBeenCalledTimes(2);
  });

  it('活动不存在、还没开始或已经结束都回 closed，不记抽签', async () => {
    const device = await registered();
    expect((await draw(device, 'no-such-campaign', { activeDays: 3 })).body).toEqual({ result: 'closed', sealed: null });
    const later = await setup({ from: hour, to: 2 * hour });
    expect((await draw(device, later, { activeDays: 3 })).body.result).toBe('closed');
    const ended = await setup({ from: -2 * hour, to: -hour });
    expect((await draw(device, ended, { activeDays: 3 })).body.result).toBe('closed');
    expect(roll).not.toHaveBeenCalled();
  });

  it('抽中给出奖品（只有抽签的设备打得开）；同一个人再来返回同一个奖品，没抽中的再来也还是没抽中（不能重抽）；库里只存账号号的哈希', async () => {
    const key = await setup();
    const luckySubject = randomBytes(16).toString('base64url'), unluckySubject = randomBytes(16).toString('base64url');
    const lucky = await registered(luckySubject), unlucky = await registered(unluckySubject);
    roll.mockReturnValue(0);
    const won = await draw(lucky, key, { activeDays: 5 });
    expect(won.status).toBe(200);
    expect(won.body.result).toBe('won');
    expect(JSON.stringify(won.body)).not.toContain('口令0');
    expect(prizeOf(lucky, key, won.body)).toEqual({ kind: 'password', content: '口令0', note: '附言0' });
    expect(() => prizeOf(unlucky, key, won.body), '别的设备打不开').toThrow();
    expect(() => prizeOf(lucky, `${key}x`, won.body), '换个活动编号打不开').toThrow();
    roll.mockReturnValue(0.99);
    const again = await draw(lucky, key, { activeDays: 30 });
    expect(again.body.sealed, '每次另起一次性密钥重新封').not.toBe(won.body.sealed);
    expect(prizeOf(lucky, key, again.body)).toEqual(prizeOf(lucky, key, won.body));
    expect((await draw(unlucky, key, { activeDays: 5 })).body).toEqual({ result: 'missed', sealed: null });
    roll.mockReturnValue(0);
    expect((await draw(unlucky, key, { activeDays: 5 })).body.result).toBe('missed');
    const hashes = (await database.query('SELECT participant_hash AS hash FROM reward_draw d JOIN reward_campaign c ON c.id = d.campaign_id WHERE c.campaign_key = ?', [key])) as { hash: string }[];
    expect(hashes.map((row) => row.hash).sort()).toEqual([luckySubject, unluckySubject].map(participantHash).sort());
  });

  // [人工决策-2026-11-17 21:24:25] 奖品信封加服务器认证：带 seal: 2 的（11-17 起的客户端）给第 2 版，没带的旧客户端照旧第 1 版。
  it('请求带 seal: 2 给第 2 版信封：末尾是服务器签名、绑定活动与设备，改一个字节或挪给别的设备都验不过；没带的照旧第 1 版；seal 只认 2', async () => {
    const key = await setup();
    const account = randomBytes(16).toString('base64url');
    const device = await registered(account), other = await registered(randomBytes(16).toString('base64url'));
    roll.mockReturnValue(0);
    const signed = await draw(device, key, { activeDays: 5, seal: 2 });
    expect(signed.body.result).toBe('won');
    const sealed = Buffer.from(signed.body.sealed, 'base64url');
    expect(sealed[0]).toBe(2);
    expect(prizeOf(device, key, signed.body)).toEqual({ kind: 'password', content: '口令0', note: '附言0' });
    expect(() => prizeOf(other, key, signed.body), '别的设备验不过').toThrow('签名');
    expect(() => prizeOf(device, `${key}x`, signed.body), '别的活动验不过').toThrow('签名');
    const tampered = Buffer.from(sealed);
    tampered[50] ^= 1;
    expect(() => prizeOf(device, key, { result: 'won', sealed: tampered.toString('base64url') }), '改了密文').toThrow('签名');
    const legacy = await draw(device, key, { activeDays: 5 });
    expect(Buffer.from(legacy.body.sealed, 'base64url')[0], '旧客户端照旧第 1 版').toBe(1);
    expect(prizeOf(device, key, legacy.body)).toEqual({ kind: 'password', content: '口令0', note: '附言0' });
    expect((await draw(device, key, { activeDays: 5, seal: 3 })).body.code).toBe('INVALID_REQUEST');
  });

  it('按活跃度加权：同一个骰子点数，活跃的抽中、新用户没抽中；平权时活跃天数不起作用', async () => {
    roll.mockReturnValue(0.5);
    const weighted = await setup({ mode: 'weighted', chance: 0.2, maxWeight: 3 });
    expect((await draw(await registered(), weighted, { activeDays: 20 })).body.result).toBe('won');
    expect((await draw(await registered(), weighted, { activeDays: 0 })).body.result).toBe('missed');
    const uniform = await setup({ mode: 'uniform', chance: 0.2 });
    expect((await draw(await registered(), uniform, { activeDays: 30 })).body.result).toBe('missed');
  });

  it('按积分等级加权：同一个骰子点数，Lv5 的抽中、Lv0 的没抽中，大额档按等级倍数挑；平权时等级都不起作用', async () => {
    await mkdir(env().releasesDir, { recursive: true });
    await writeFile(rolloutFile(), JSON.stringify({ flags: [], levels, envelope: null }));
    await utimes(rolloutFile(), Date.now() / 1000 + 7, Date.now() / 1000 + 7);
    try {
      roll.mockReturnValue(0.5);
      const weighted = await setup({ mode: 'weighted', chance: 0.2, maxWeight: 3 });
      const top = await registered();
      await earn(top, 80000);
      expect((await draw(top, weighted, { activeDays: 0 })).body.result).toBe('won');
      expect((await draw(await registered(), weighted, { activeDays: 0 })).body.result).toBe('missed');

      // 两档各 2 份、都已放出：中签骰子 0、挑档骰子 0.4。Lv0 分量 2:2 落在普通档，Lv5 分量 1:(2×3) 落在大额档。
      const tiered = await setup({ mode: 'weighted', chance: 0.2, maxWeight: 3, prizes: 2, bigPrizes: 2 });
      roll.mockReturnValueOnce(0).mockReturnValueOnce(0.4);
      const plainDevice = await registered();
      expect(prizeOf(plainDevice, tiered, (await draw(plainDevice, tiered, { activeDays: 0 })).body)?.content).toBe('口令0');
      const rich = await registered();
      await earn(rich, 80000);
      roll.mockReturnValueOnce(0).mockReturnValueOnce(0.4);
      expect(prizeOf(rich, tiered, (await draw(rich, tiered, { activeDays: 0 })).body)?.content).toBe('大额0');
      expect(await runRewardAdmin(admin, ['status', tiered], lines(''))).toContain('第 0 档：2 份，已发 1 份；第 1 档：2 份，已发 1 份');

      const uniform = await setup({ mode: 'uniform', chance: 0.2, prizes: 1, bigPrizes: 1 });
      const plain = await registered();
      await earn(plain, 80000);
      roll.mockReturnValueOnce(0.5);
      expect((await draw(plain, uniform, { activeDays: 0 })).body.result).toBe('missed');
    } finally {
      await rm(rolloutFile(), { force: true });
    }
  });

  it('客户端仅本机（levels: false）时按 Lv0：同一个骰子点数 Lv5 的也没抽中；levels 只认布尔', async () => {
    await mkdir(env().releasesDir, { recursive: true });
    await writeFile(rolloutFile(), JSON.stringify({ flags: [], levels, envelope: null }));
    await utimes(rolloutFile(), Date.now() / 1000 + 7, Date.now() / 1000 + 7);
    try {
      roll.mockReturnValue(0.5);
      const weighted = await setup({ mode: 'weighted', chance: 0.2, maxWeight: 3 });
      const top = await registered();
      await earn(top, 80000);
      expect((await draw(top, weighted, { activeDays: 0, levels: 'no' })).status).toBe(400);
      expect((await draw(top, weighted, { activeDays: 0, levels: false })).body.result).toBe('missed');
      const other = await registered();
      await earn(other, 80000);
      expect((await draw(other, weighted, { activeDays: 0, levels: true })).body.result, '带 true 同不带').toBe('won');
    } finally {
      await rm(rolloutFile(), { force: true });
    }
  });

  it('均匀放量：24 小时的活动第一个小时只放 1 份，第二个抽中的人算没抽中', async () => {
    roll.mockReturnValue(0);
    const key = await setup({ from: -hour / 2, to: 23.5 * hour, prizes: 24 });
    expect((await draw(await registered(), key, { activeDays: 1 })).body.result).toBe('won');
    expect((await draw(await registered(), key, { activeDays: 1 })).body.result).toBe('missed');
  });

  it('并发：12 个人同时抽中、只有 5 份奖品，正好发出 5 份且各不相同；同一个人并发 5 次只记一次', async () => {
    roll.mockReturnValue(0);
    const key = await setup({ prizes: 5 });
    const devices = await Promise.all(Array.from({ length: 12 }, () => registered()));
    const results = await Promise.all(devices.map((device) => draw(device, key, { activeDays: 1 })));
    const prizes = results.flatMap((response, index) => (response.body.result === 'won' ? [prizeOf(devices[index], key, response.body)!.content] : []));
    expect(prizes).toHaveLength(5);
    expect(new Set(prizes).size).toBe(5);
    const again = await setup({ prizes: 5 });
    const same = await registered();
    const repeated = await Promise.all(Array.from({ length: 5 }, () => draw(same, again, { activeDays: 1 })));
    expect(new Set(repeated.map((response) => JSON.stringify(prizeOf(same, again, response.body)))).size).toBe(1);
    const [counted] = (await database.query('SELECT COUNT(*) AS draws FROM reward_draw d JOIN reward_campaign c ON c.id = d.campaign_id WHERE c.campaign_key = ?', [again])) as { draws: string }[];
    expect(Number(counted.draws)).toBe(1);
  });

  it('参数不合法回 INVALID_REQUEST；请求体只认 activeDays，带上旧的参与号也不收', async () => {
    const key = await setup();
    const device = await registered();
    for (const body of [{ activeDays: 31 }, { activeDays: -1 }, {}, { activeDays: 1, extra: 1 }, { participant: 'AAAAAAAAAAAAAAAAAAAAAA', activeDays: 1 }]) {
      const response = await draw(device, key, body);
      expect(response.status).toBe(400);
      expect(response.body.code).toBe('INVALID_REQUEST');
    }
    expect((await draw(device, 'Bad_Key', { activeDays: 1 })).status).toBe(400);
  });

  // 把这一小时的计数直接拨到上限（同一个固定窗口），下一次就超了。
  const exhaust = async (scope: string, limit: number) => {
    const redis = app.get<Redis>(REDIS);
    const prefix = redis.options.keyPrefix ?? '';
    const [, keys] = await redis.scan('0', 'MATCH', `${prefix}${RedisKeys.rate(scope, '*', 0).replace(/:0$/, '')}:*`, 'COUNT', 1000);
    expect(keys).toHaveLength(1);
    await redis.set(keys[0].slice(prefix.length), limit, 'KEEPTTL');
  };

  it('账号建立不满 7 天回 ACCOUNT_TOO_NEW 并附可以抽的时刻，不记这次；满了照常抽', async () => {
    const key = await setup();
    roll.mockReturnValue(0);
    const young = await registered(randomBytes(16).toString('base64url'), new Date(Date.now() - 2 * 86400_000));
    const refused = await draw(young, key, { activeDays: 3 });
    expect(refused.status).toBe(403);
    expect(refused.body.code).toBe('ACCOUNT_TOO_NEW');
    expect(Math.abs((refused.body.eligibleAt as number) - (Date.now() + 5 * 86400_000))).toBeLessThan(60_000);
    expect(await database.query('SELECT d.id FROM reward_draw d JOIN reward_campaign c ON c.id = d.campaign_id WHERE c.campaign_key = ?', [key])).toHaveLength(0);
    await database.query('UPDATE app_account SET create_time = ? WHERE account_id = (SELECT account_id FROM account_device WHERE device_id = ?)', [new Date(Date.now() - 8 * 86400_000), young.deviceId]);
    expect((await draw(young, key, { activeDays: 3 })).body.result).toBe('won');
  });

  it('同一台设备每小时超过上限回 RATE_LIMITED，同一出口的别的设备不受影响', async () => {
    vi.spyOn(Date, 'now').mockReturnValue((Math.floor(Date.now() / hour) + 0.5) * hour);
    const key = await setup();
    const device = await registered(), neighbor = await registered();
    await draw(device, key, { activeDays: 1 });
    await exhaust('reward_device', rewardDrawPerDevicePerHour);
    const response = await draw(device, key, { activeDays: 1 });
    expect(response.status).toBe(429);
    expect(response.body.code).toBe('RATE_LIMITED');
    expect((await draw(neighbor, key, { activeDays: 1 })).status).toBe(200);
  });

  it('同一 IP 每小时超过上限回 RATE_LIMITED', async () => {
    vi.spyOn(Date, 'now').mockReturnValue((Math.floor(Date.now() / hour) + 0.5) * hour);
    const key = await setup();
    const device = await registered();
    await draw(device, key, { activeDays: 1 });
    await exhaust('reward_draw', rewardDrawPerHour);
    const response = await draw(await registered(), key, { activeDays: 1 });
    expect(response.status).toBe(429);
    expect(response.body.code).toBe('RATE_LIMITED');
  });

  it('设备删除自己（DELETE /v1/devices）后不能再抽；抽签记录照旧留到活动保留期', async () => {
    roll.mockReturnValue(0.99);
    const key = await setup();
    const subject = randomBytes(16).toString('base64url');
    const device = await registered(subject);
    expect((await draw(device, key, { activeDays: 2 })).body.result).toBe('missed');
    expect((await device.call('DELETE', '/v1/devices')).status).toBe(204);
    const after = await draw(device, key, { activeDays: 2 });
    expect(after.status).toBe(401);
    const [counted] = (await database.query('SELECT COUNT(*) AS draws FROM reward_draw WHERE participant_hash = ?', [participantHash(subject)])) as { draws: string }[];
    expect(Number(counted.draws)).toBe(1);
  });
});

describe('维护命令与保留', () => {
  it('输入不对时说清楚是哪里；status 汇总奖品与抽签', async () => {
    await expect(runRewardAdmin(admin, ['create', 'x', '--from', '2027-02-06T00:00', '--to', '2027-02-07T00:00+08:00', '--mode', 'uniform', '--chance', '0.2'], lines(''))).rejects.toThrow(RewardAdminError);
    await expect(runRewardAdmin(admin, ['create', 'x', '--from', '2027-02-06T00:00+08:00', '--to', '2027-02-07T00:00+08:00', '--mode', 'lucky', '--chance', '0.2'], lines(''))).rejects.toThrow('--mode');
    await expect(runRewardAdmin(admin, ['import', 'no-such'], lines('口令\ta'))).rejects.toThrow('先 create');
    const key = await setup({ prizes: 0 });
    await expect(runRewardAdmin(admin, ['import', key], lines('口令\ta\n红包\tb'))).rejects.toThrow('第 2 行');
    await expect(runRewardAdmin(admin, ['import', key, '--tier', '10'], lines('口令\ta'))).rejects.toThrow('--tier');
    expect(await runRewardAdmin(admin, ['import', key], lines('﻿口令\ta\n\n二维码\thttps://qr.alipay.com/demo\t扫码领'))).toContain('prizes=2');
    roll.mockReturnValue(0);
    await draw(await registered(), key, { activeDays: 4 });
    const status = await runRewardAdmin(admin, ['status', key], lines(''));
    expect(status).toContain('奖品 2 份，已发 1 份');
    expect(status).toContain('抽签 1 人，中 1 人');
  });

  // 命令行入口用 readline 读标准输入：import 先查活动再读，读之前已经发出的行不能丢；不读输入的命令不碰标准输入（不然进程等输入结束、不退出）。
  it('import 先查活动再读标准输入也不丢行；create 与 status 不读标准输入', async () => {
    const key = await setup({ prizes: 0 });
    const input = new PassThrough();
    input.end('口令\t甲\n二维码\t乙\n');
    expect(await runRewardAdmin(admin, ['import', key], () => createInterface({ input, crlfDelay: Infinity }))).toContain('prizes=2');
    const untouched = () => {
      throw new Error('不该读标准输入');
    };
    expect(await runRewardAdmin(admin, ['status', key], untouched)).toContain('奖品 2 份');
  });

  it('活动结束 30 天后连同奖品与抽签记录删除，没到期的不动', async () => {
    roll.mockReturnValue(0);
    const device = await registered();
    const old = await setup();
    await draw(device, old, { activeDays: 1 });
    const recent = await setup();
    await draw(device, recent, { activeDays: 1 });
    const ended = new Date(Date.now() - (rewardKeepDays + 1) * 86400_000);
    await database.query('UPDATE reward_campaign SET starts_at = ?, ends_at = ? WHERE campaign_key = ?', [new Date(ended.getTime() - hour), ended, old]);
    await app.get(RewardRetentionTask).sweep();
    const count = async (key: string) => {
      const [row] = (await database.query(
        'SELECT (SELECT COUNT(*) FROM reward_campaign WHERE campaign_key = ?) AS campaigns, (SELECT COUNT(*) FROM reward_prize p JOIN reward_campaign c ON c.id = p.campaign_id WHERE c.campaign_key = ?) AS prizes',
        [key, key],
      )) as { campaigns: string; prizes: string }[];
      return [Number(row.campaigns), Number(row.prizes)];
    };
    expect(await count(old)).toEqual([0, 0]);
    expect(await count(recent)).toEqual([1, 3]);
    const [orphans] = (await database.query('SELECT COUNT(*) AS draws FROM reward_draw WHERE campaign_id NOT IN (SELECT id FROM reward_campaign)')) as { draws: string }[];
    expect(Number(orphans.draws)).toBe(0);
  });
});

// 11-16 起资格与发放由活动参数决定（人工决策见 src/modules/reward/reward_odds.ts 的 11-16 那条）。
describe('资格与发放', () => {
  const create = async (extra: string[], prizes = 3) => {
    const key = campaignKey();
    const now = Date.now();
    await runRewardAdmin(admin, ['create', key, '--from', new Date(now - hour / 2).toISOString(), '--to', new Date(now + 23.5 * hour).toISOString(), ...extra], lines(''));
    if (prizes > 0) await runRewardAdmin(admin, ['import', key], lines(Array.from({ length: prizes }, (_, index) => `口令\t口令${index}`).join('\n')));
    return key;
  };
  const accountOf = async (device: TestDevice) => {
    const [row] = (await database.query('SELECT a.account_id AS accountId, a.username FROM account_device d JOIN app_account a ON a.account_id = d.account_id WHERE d.device_id = ?', [device.deviceId])) as {
      accountId: string;
      username: string;
    }[];
    return row;
  };
  const status = async (device: TestDevice, key: string, query = '') => {
    const response = await device.call('GET', `/v1/rewards/${key}${query}`);
    expect(response.status, JSON.stringify(response.body)).toBe(200);
    return response.body as { state: string; endsAt: string | null; eligibleAt: number | null };
  };
  const draws = async (key: string) =>
    Number(((await database.query('SELECT COUNT(*) AS count FROM reward_draw d JOIN reward_campaign c ON c.id = d.campaign_id WHERE c.campaign_key = ?', [key])) as { count: string }[])[0].count);

  it('all：有资格就发、不掷骰子、不按小时放量，发完为止；平权一档就是等额', async () => {
    roll.mockReturnValue(0.999);
    const key = await create(['--distribution', 'all']);
    const results = [];
    for (let index = 0; index < 4; index++) {
      const device = await registered();
      const body = (await draw(device, key, { activeDays: 0 })).body as { result: string; sealed: string | null };
      results.push(body.result === 'won' ? prizeOf(device, key, body)!.content : body.result);
    }
    expect(results).toEqual(['口令0', '口令1', '口令2', 'sold_out']);
    expect(roll).not.toHaveBeenCalled();
    expect(await runRewardAdmin(admin, ['status', key], lines(''))).toContain('发放 all');
  });

  // 11-28 Codex 审查 F07：抽中时原来汇总这次活动的全部奖品；改成每档一行计数，导入与发出时同一事务里改。
  it('每档的库存计数跟着导入与发出走、和奖品表对得上；导入中途有一行不对整批不进库、计数不变', async () => {
    roll.mockReturnValue(0.999);
    const key = await create(['--distribution', 'all', '--min-account-days', '0'], 2);
    const stock = async () =>
      (await database.query('SELECT s.tier, s.stock, s.given FROM reward_tier_stock s JOIN reward_campaign c ON c.id = s.campaign_id WHERE c.campaign_key = ? ORDER BY s.tier', [key])) as { tier: number; stock: number; given: number }[];
    expect(await stock()).toEqual([{ tier: 0, stock: 2, given: 0 }]);
    expect((await draw(await registered(), key, { activeDays: 0 })).body).toMatchObject({ result: 'won' });
    expect(await stock()).toEqual([{ tier: 0, stock: 2, given: 1 }]);
    await expect(runRewardAdmin(admin, ['import', key], lines('口令\t补1\n红包\t不认识'))).rejects.toThrow('第 2 行');
    expect(await stock()).toEqual([{ tier: 0, stock: 2, given: 1 }]);
    await runRewardAdmin(admin, ['import', key], lines('口令\t补1\n口令\t补2'));
    await runRewardAdmin(admin, ['import', key, '--tier', '1'], lines('口令\t大额'));
    expect(await stock()).toEqual([
      { tier: 0, stock: 4, given: 1 },
      { tier: 1, stock: 1, given: 0 },
    ]);
    const [counted] = (await database.query('SELECT COUNT(*) AS total, COUNT(draw_id) AS given FROM reward_prize p JOIN reward_campaign c ON c.id = p.campaign_id WHERE c.campaign_key = ?', [key])) as { total: string; given: string }[];
    expect([Number(counted.total), Number(counted.given)]).toEqual([5, 1]);
  });

  // 人工决策见 src/modules/reward/reward_odds.ts 的 11-18 那条：发完为止的活动分批补货。
  it('all 分批补货：这一批领完时来领的人回 sold_out、不记这次，状态 sold_out；补货后同一个人能领到，领过的照旧拿回自己那份', async () => {
    const key = await create(['--distribution', 'all', '--min-account-days', '0'], 1);
    const first = await registered(), late = await registered();
    expect((await draw(first, key, { activeDays: 0 })).body).toMatchObject({ result: 'won' });
    expect(await status(late, key)).toMatchObject({ state: 'sold_out' });
    expect((await draw(late, key, { activeDays: 0 })).body).toEqual({ result: 'sold_out', sealed: null });
    expect(await draws(key)).toBe(1);
    await runRewardAdmin(admin, ['import', key], lines('口令\t补货0'));
    expect(await status(late, key)).toMatchObject({ state: 'open' });
    const body = (await draw(late, key, { activeDays: 0 })).body as { result: string; sealed: string | null };
    expect(prizeOf(late, key, body)!.content).toBe('补货0');
    expect(await status(first, key)).toMatchObject({ state: 'drawn' });
    const again = (await draw(first, key, { activeDays: 0 })).body as { result: string; sealed: string | null };
    expect(prizeOf(first, key, again)!.content).toBe('口令0');
    expect(await draws(key)).toBe(2);
  });

  it('名单：按用户名导入（不分大小写、报出对不上的），名单里的人能领，名单外的是 ineligible 且不记这次；状态 open、ineligible、drawn、closed', async () => {
    roll.mockReturnValue(0.999);
    const key = await create(['--distribution', 'all', '--audience', 'list']);
    const listed = await registered(), outsider = await registered();
    const { username } = await accountOf(listed);
    const imported = await runRewardAdmin(admin, ['audience', key], lines(`${username.toUpperCase()}\n\n${username}\nnobody_here\n`));
    expect(imported).toContain('names=2 added=1 unknown=1');
    expect(imported).toContain('nobody_here');
    expect((await runRewardAdmin(admin, ['audience', key], lines(username))).includes('added=0')).toBe(true);
    expect(await status(listed, key)).toMatchObject({ state: 'open', eligibleAt: null });
    expect((await status(outsider, key)).state).toBe('ineligible');
    expect((await draw(outsider, key, { activeDays: 0 })).body).toEqual({ result: 'ineligible', sealed: null });
    expect(await draws(key)).toBe(0);
    const won = (await draw(listed, key, { activeDays: 0 })).body as { result: string; sealed: string | null };
    expect(prizeOf(listed, key, won)?.content).toBe('口令0');
    expect((await status(listed, key)).state).toBe('drawn');
    // 活动行在进程内缓存 60 秒，改库的结束时刻这里看不到；没有的活动是 closed。
    expect(await status(listed, 'no-such-campaign')).toEqual({ state: 'closed', endsAt: null, eligibleAt: null });
    await expect(runRewardAdmin(admin, ['audience', key], lines('Bad Name!'))).rejects.toThrow(RewardAdminError);
  });

  it('账号满几天每个活动自己定：0 天新账号也能领，默认 7 天，30 天的 8 天账号是 ACCOUNT_TOO_NEW；状态 too_new 附可以领的时刻', async () => {
    roll.mockReturnValue(0);
    const fresh = await registered(undefined, new Date());
    expect((await draw(fresh, await create(['--mode', 'uniform', '--chance', '0.5', '--min-account-days', '0']), { activeDays: 0 })).body.result).toBe('won');
    const standard = await create(['--mode', 'uniform', '--chance', '0.5']);
    expect((await draw(fresh, standard, { activeDays: 0 })).body.code).toBe('ACCOUNT_TOO_NEW');
    const strict = await create(['--mode', 'uniform', '--chance', '0.5', '--min-account-days', '30']);
    const week = await registered();
    const refused = await draw(week, strict, { activeDays: 0 });
    expect(refused.body.code).toBe('ACCOUNT_TOO_NEW');
    const state = await status(week, strict);
    expect(state.state).toBe('too_new');
    expect(state.eligibleAt).toBe(refused.body.eligibleAt);
    expect(await draws(strict)).toBe(0);
    await expect(runRewardAdmin(admin, ['create', campaignKey(), '--from', new Date().toISOString(), '--to', new Date(Date.now() + hour).toISOString(), '--distribution', 'all', '--min-account-days', '-1'], lines(''))).rejects.toThrow(/min-account-days/);
  });

  it('最低等级：不够的 ineligible，够的能领；仅本机（levels false、状态 levels=0）按 Lv0', async () => {
    await mkdir(env().releasesDir, { recursive: true });
    await writeFile(rolloutFile(), JSON.stringify({ flags: [], levels, envelope: null }));
    await utimes(rolloutFile(), Date.now() / 1000 + 9, Date.now() / 1000 + 9);
    try {
      const key = await create(['--distribution', 'all', '--min-level', '2']);
      const low = await registered(), high = await registered();
      await earn(high, 3000);
      expect((await status(low, key)).state).toBe('ineligible');
      expect((await draw(low, key, { activeDays: 0 })).body.result).toBe('ineligible');
      expect((await status(high, key)).state).toBe('open');
      expect((await status(high, key, '?levels=0')).state).toBe('ineligible');
      expect((await draw(high, key, { activeDays: 0, levels: false })).body.result).toBe('ineligible');
      expect((await draw(high, key, { activeDays: 0 })).body.result).toBe('won');
      expect((await high.call('GET', `/v1/rewards/${key}?levels=no`)).body.code).toBe('INVALID_REQUEST');
    } finally {
      await rm(rolloutFile(), { force: true });
    }
  });

  it('名单随注销账号删除，随活动保留期删除', async () => {
    const key = await create(['--distribution', 'all', '--audience', 'list']);
    const device = await registered();
    const { username, accountId } = await accountOf(device);
    await runRewardAdmin(admin, ['audience', key], lines(username));
    const audience = async () => Number(((await database.query('SELECT COUNT(*) AS count FROM reward_audience WHERE account_id = ?', [accountId])) as { count: string }[])[0].count);
    expect(await audience()).toBe(1);
    expect((await device.call('DELETE', '/v1/account')).status).toBe(204);
    expect(await audience()).toBe(0);
    const other = await registered();
    const second = await accountOf(other);
    await runRewardAdmin(admin, ['audience', key], lines(second.username));
    const ended = new Date(Date.now() - (rewardKeepDays + 1) * 86400_000);
    await database.query('UPDATE reward_campaign SET starts_at = ?, ends_at = ? WHERE campaign_key = ?', [new Date(ended.getTime() - hour), ended, key]);
    await app.get(RewardRetentionTask).sweep();
    expect(Number(((await database.query('SELECT COUNT(*) AS count FROM reward_audience WHERE account_id = ?', [second.accountId])) as { count: string }[])[0].count)).toBe(0);
  });
});

// 11-28 Codex 复核 F07：每档计数的回滚、并发、迁移回填与执行计划要有对应的证据，不能只靠结构一致。
describe('每档的库存计数：回滚、并发、迁移与执行计划', () => {
  const create = async (prizes: number) => {
    const key = campaignKey();
    const now = Date.now();
    await runRewardAdmin(admin, ['create', key, '--from', new Date(now - hour / 2).toISOString(), '--to', new Date(now + 23.5 * hour).toISOString(), '--distribution', 'all', '--min-account-days', '0'], lines(''));
    if (prizes > 0) await runRewardAdmin(admin, ['import', key], lines(Array.from({ length: prizes }, (_, index) => `口令\t口令${index}`).join('\n')));
    return key;
  };
  const campaignId = async (key: string) => ((await database.query('SELECT id FROM reward_campaign WHERE campaign_key = ?', [key])) as { id: string }[])[0].id;
  const counters = async (key: string) =>
    ((await database.query('SELECT s.tier, s.stock, s.given FROM reward_tier_stock s JOIN reward_campaign c ON c.id = s.campaign_id WHERE c.campaign_key = ? ORDER BY s.tier', [key])) as { tier: number; stock: number; given: number }[]).map(
      (row) => ({ tier: Number(row.tier), stock: Number(row.stock), given: Number(row.given) }),
    );
  // 奖品表按档汇总（计数应当等于它）。
  const actual = async (key: string) =>
    ((await database.query('SELECT p.tier, COUNT(*) AS stock, COUNT(p.draw_id) AS given FROM reward_prize p JOIN reward_campaign c ON c.id = p.campaign_id WHERE c.campaign_key = ? GROUP BY p.tier ORDER BY p.tier', [key])) as { tier: number; stock: string; given: string }[]).map(
      (row) => ({ tier: Number(row.tier), stock: Number(row.stock), given: Number(row.given) }),
    );

  it('导入第一批 1000 份已经写进事务、第 1002 行不对：整个导入回滚，奖品与计数都不变', async () => {
    const key = await create(2);
    const valid = Array.from({ length: 1001 }, (_, index) => `口令\t大批${index}`);
    await expect(runRewardAdmin(admin, ['import', key], lines([...valid, '红包\t不认识'].join('\n')))).rejects.toThrow('第 1002 行');
    expect(await actual(key)).toEqual([{ tier: 0, stock: 2, given: 0 }]);
    expect(await counters(key)).toEqual([{ tier: 0, stock: 2, given: 0 }]);
  });

  it('抽中时最后一步（加已发计数）之后出错：整次抽签回滚，奖品没发出、计数不变、不留抽签记录；再抽照常', async () => {
    const key = await create(1);
    const device = await registered();
    const original = EntityManager.prototype.query;
    const spy = vi.spyOn(EntityManager.prototype, 'query').mockImplementation(async function (this: EntityManager, ...args: Parameters<EntityManager['query']>) {
      const result = await original.apply(this, args);
      if (String(args[0]).startsWith('UPDATE reward_tier_stock SET given')) throw new Error('synthetic failure after given');
      return result;
    });
    try {
      expect((await draw(device, key, { activeDays: 0 })).status).toBe(500);
    } finally {
      spy.mockRestore();
    }
    expect(await counters(key)).toEqual([{ tier: 0, stock: 1, given: 0 }]);
    expect(await actual(key)).toEqual([{ tier: 0, stock: 1, given: 0 }]);
    expect(Number(((await database.query('SELECT COUNT(*) AS count FROM reward_draw WHERE campaign_id = ?', [await campaignId(key)])) as { count: string }[])[0].count)).toBe(0);
    expect((await draw(device, key, { activeDays: 0 })).body.result).toBe('won');
    expect(await counters(key)).toEqual([{ tier: 0, stock: 1, given: 1 }]);
  });

  it('导入与抽签同时进行：发出的不超过库存、一份不发两次，结束后计数与奖品表一致', async () => {
    const key = await create(3);
    const devices = await Promise.all(Array.from({ length: 8 }, () => registered()));
    const importing = runRewardAdmin(admin, ['import', key], lines(Array.from({ length: 1500 }, (_, index) => `口令\t并发${index}`).join('\n')));
    const drawing = Promise.all(devices.map((device) => draw(device, key, { activeDays: 0 })));
    const [, responses] = await Promise.all([importing, drawing]);
    const won = responses.filter((response) => response.body.result === 'won').length;
    expect(won + responses.filter((response) => response.body.result === 'sold_out').length).toBe(8);
    expect(await counters(key)).toEqual(await actual(key));
    expect(await counters(key)).toEqual([{ tier: 0, stock: 1503, given: won }]);
    const [duplicates] = (await database.query('SELECT COUNT(*) AS count FROM (SELECT draw_id FROM reward_prize WHERE campaign_id = ? AND draw_id IS NOT NULL GROUP BY draw_id HAVING COUNT(*) > 1) d', [await campaignId(key)])) as { count: string }[];
    expect(Number(duplicates.count)).toBe(0);
  });

  it('活动过了保留期：计数行与奖品、抽签记录一起删', async () => {
    const key = await create(2);
    await draw(await registered(), key, { activeDays: 0 });
    const id = await campaignId(key);
    const ended = new Date(Date.now() - (rewardKeepDays + 1) * 86400_000);
    await database.query('UPDATE reward_campaign SET starts_at = ?, ends_at = ? WHERE id = ?', [new Date(ended.getTime() - hour), ended, id]);
    await app.get(RewardRetentionTask).sweep();
    expect(await database.query('SELECT id FROM reward_tier_stock WHERE campaign_id = ?', [id])).toHaveLength(0);
    expect(await database.query('SELECT id FROM reward_prize WHERE campaign_id = ?', [id])).toHaveLength(0);
  });

  // 线上的升级顺序（server/README.md「表结构升级台账」与部署一节）：先跑 upgrade_2026_11_28.sql 回填、再换新版；换版期间旧版发出的份数不加计数，换完再跑一次校正。
  it('迁移回填：按奖品表算出每档计数；旧版在换版期间又发出的，再跑一次就校正；重复执行结果不变', async () => {
    const statements = (await readFile(join(__dirname, '..', 'sql', 'upgrade_2026_11_28.sql'), 'utf8'))
      .split('\n')
      .filter((line) => !line.trimStart().startsWith('--'))
      .join('\n')
      .split(';')
      .map((statement) => statement.trim())
      .filter((statement) => statement !== '');
    expect(statements).toHaveLength(2);
    const upgrade = async () => {
      for (const statement of statements) await database.query(statement);
    };
    const key = await create(3);
    await runRewardAdmin(admin, ['import', key, '--tier', '1'], lines('口令\t大额0'));
    await draw(await registered(), key, { activeDays: 0 });
    const id = await campaignId(key);
    const before = await counters(key);
    // 升级之前的库：还没有这几行计数。
    await database.query('DELETE FROM reward_tier_stock WHERE campaign_id = ?', [id]);
    await upgrade();
    expect(await counters(key)).toEqual(before);
    expect(await counters(key)).toEqual(await actual(key));
    // 换版期间旧版发出一份：只改奖品行、不加计数。
    const [{ prizeId }] = (await database.query('SELECT id AS prizeId FROM reward_prize WHERE campaign_id = ? AND tier = 0 AND draw_id IS NULL LIMIT 1', [id])) as { prizeId: string }[];
    await database.query('UPDATE reward_prize SET draw_id = 999999999 WHERE id = ?', [prizeId]);
    expect(await counters(key)).not.toEqual(await actual(key));
    await upgrade();
    expect(await counters(key)).toEqual(await actual(key));
    await upgrade();
    expect(await counters(key)).toEqual(await actual(key));
  });

  it('五万份库存时抽中的两条查询都走索引、实际只读一两行（不随库存增长）；还剩多少只读每档一行', async () => {
    const key = await create(0);
    const id = await campaignId(key);
    // 一次插入五万份合成奖品（十个数字自连五次再截取），计数行同步写上。
    await database.query(
      `INSERT INTO reward_prize (campaign_id, tier, kind, content, note, create_time, update_time)
       SELECT ?, 0, 'password', CONCAT('批量', seq.n), '', NOW(3), NOW(3) FROM (
         SELECT a.n + b.n * 10 + c.n * 100 + d.n * 1000 + e.n * 10000 AS n
         FROM (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
         CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b
         CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c
         CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d
         CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) e
       ) seq`,
      [id],
    );
    await database.query('INSERT INTO reward_tier_stock (campaign_id, tier, stock, given, create_time, update_time) VALUES (?, 0, 50000, 0, NOW(3), NOW(3))', [id]);
    await database.query('ANALYZE TABLE reward_prize, reward_tier_stock');
    // EXPLAIN ANALYZE 给出每一步实际读的行数（rows=）。
    const readRows = async (sql: string, params: unknown[]) => {
      const [row] = (await database.query(`EXPLAIN ANALYZE ${sql}`, params)) as Record<string, string>[];
      const plan = Object.values(row)[0];
      const rows = [...plan.matchAll(/actual time=[^)]*rows=(\d+)/g)].map((match) => Number(match[1]));
      expect(rows.length, plan).toBeGreaterThan(0);
      if (process.env.SHOW_PLANS !== undefined) await writeFile(process.env.SHOW_PLANS, plan + '\n\n', { flag: 'a' });
      return { plan, rows };
    };
    const tiers = await readRows('SELECT tier, stock, given FROM reward_tier_stock WHERE campaign_id = ?', [id]);
    expect(tiers.plan).toContain('uk_reward_tier_stock');
    expect(Math.max(...tiers.rows), tiers.plan).toBeLessThanOrEqual(1);
    const prize = await readRows('SELECT id, kind, content, note FROM reward_prize WHERE campaign_id = ? AND tier = ? AND draw_id IS NULL ORDER BY id LIMIT 1', [id, 0]);
    expect(prize.plan).toContain('idx_campaign_tier_draw');
    expect(Math.max(...prize.rows), prize.plan).toBeLessThanOrEqual(1);
    const left = await readRows('SELECT COALESCE(SUM(stock - given), 0) AS count FROM reward_tier_stock WHERE campaign_id = ?', [id]);
    expect(Math.max(...left.rows), left.plan).toBeLessThanOrEqual(1);
    // 真抽一次：拿到第一份，计数加一。
    expect((await draw(await registered(), key, { activeDays: 0 })).body.result).toBe('won');
    expect(await counters(key)).toEqual([{ tier: 0, stock: 50000, given: 1 }]);
  });
});
