import { HttpStatus, Inject, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import Redis from 'ioredis';
import { randomBytes, randomInt, timingSafeEqual } from 'node:crypto';

import { rateSubjectOf } from 'src/common/client_ip';
import { IpRegion } from 'src/common/ip_region';
import { RateLimiter, REDIS } from 'src/common/redis/redis.module';
import { RedisKeys, RedisKeyTTL } from 'src/common/redis/redis_keys';
import { RelayCode, RelayError } from 'src/common/relay_error';
import {
  accountApprovePerDevicePerHour,
  accountJoinPerDevicePerHour,
  accountJoinPerSourcePerHour,
  accountLoginPerSourcePerHour,
  accountLoginPerUserPerHour,
  accountLoginPerUserSourcePerHour,
  accountRegisterPerDevicePerHour,
  accountRegisterPerSourcePerHour,
  accountSealMaxBytes,
  accountSecretChangePerDevicePerHour,
} from 'src/common/relay_limits';
import { decodeBase64url } from 'src/common/crypto/relay_crypto';
import { AccountRepository } from 'src/modules/account/account.repository';
import { AccountKeys } from 'src/modules/account/account_keys';
import { DeviceService } from 'src/modules/device/device.service';
import * as dtos from 'src/modules/account/account.dto';

// 恢复码：客户端生成的 24 位 Crockford base32（120 位随机），交来的是去掉分隔符的大写规范写法。
const recoveryCodePattern = /^[0-9A-HJKMNP-TV-Z]{24}$/;
const passwordLength = { min: 8, max: 64 };

// [人工决策-2026-11-15 16:40:33] 应用账号改为自己的账号体系（学校挡了中转的 IP、教务又是明文 http，服务器核实不了学号；用户说「别依赖教务系统账号了」）：
// 用户名加密码（用户选，不收手机号与邮箱）；忘了密码用注册时给的恢复码重设，或在登录着的手机上直接改（用户选，不做人工找回）；
// 应用账号与教务各管各的（用户选，取代 11-13 的「跟着教务走」）；11-13 起用教务核对登录的老账号全部清掉、重新注册（用户选，见 sql/upgrade_2026_11_15b.sql）。
// 11-15 的设备核对、3 天找回与更早的中转代登录教务都作废、代码删除。密码与恢复码在客户端用中转公钥封装（中转是明文 HTTP），这里只存 scrypt 哈希。
// 用户名、密码、恢复码哪一项不对都只回 CREDENTIALS_INVALID，不说是哪一项；注册时用户名被占用是例外（先到先得，没法不说）。
// [人工决策-2026-11-15 19:18:31] 账号安全加固（用户在审查报告里全选推荐）：凭恢复码重设后账号下其他设备都下线（recover，改密码不动）；
// 扫码登录批准前给批准方看请求方的机型与属地（startJoin、inspectJoin）；离开出示页时作废票据（cancelJoin）；
// 注销时给账号的密钥记墓碑、再来的回 ACCOUNT_DELETED（remove、missing），客户端只在这时清本机那个账号的私信；账号下任一设备有签名请求就按小时记活跃（onModuleInit）。
@Injectable()
export class AccountService implements OnModuleInit {
  private readonly logger = new Logger('Account');

  constructor(
    private readonly accounts: AccountRepository,
    private readonly keys: AccountKeys,
    private readonly devices: DeviceService,
    private readonly limiter: RateLimiter,
    private readonly regions: IpRegion,
    @Inject(REDIS) private readonly redis: Redis,
  ) {}

  // 账号下的设备有签名请求时（设备模块每台每小时通知一次，热路径不等）记账号的最后活跃，400 天不活跃清理按它算；设备模块不知道账号。
  onModuleInit() {
    this.devices.onSeen((deviceId) => this.accounts.touchOf(deviceId, new Date()));
  }

  // 这把密钥没登录：注销过的账号（墓碑还在）回 ACCOUNT_DELETED，客户端据此清掉本机那个账号的私信；其余（被顶掉、重设踢下线、从没登录）回 ACCOUNT_NOT_FOUND。
  private async missing(deviceId: string): Promise<never> {
    if (await this.accounts.deletedOf(deviceId)) throw new RelayError(RelayCode.accountDeleted, HttpStatus.GONE, '应用账号已注销');
    throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
  }

  private async accountOrMissing(deviceId: string) {
    return (await this.accounts.accountOf(deviceId)) ?? (await this.missing(deviceId));
  }

  private async limit(scope: string, subject: string, limit: number, window: number, message: string) {
    const retryAfter = await this.limiter.hit(scope, subject, limit, window);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, message, { retryAfter });
  }

  // 打开信封、按字段校验（外部输入，多一项少一项都不认）。
  private secretsOf<K extends string>(sealedText: string, deviceId: string, names: readonly K[]): Record<K, string> {
    const sealed = decodeBase64url(sealedText);
    const plain = sealed === null || sealed.length > accountSealMaxBytes ? null : this.keys.open(sealed, deviceId);
    let value: unknown = null;
    try {
      value = plain === null ? null : JSON.parse(plain.toString('utf8'));
    } catch {
      value = null;
    }
    const record = typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
    const valid = record !== null && Object.keys(record).length === names.length && names.every((name) => {
      const item = record[name];
      if (typeof item !== 'string') return false;
      if (name === 'password') return [...item].length >= passwordLength.min && [...item].length <= passwordLength.max;
      return recoveryCodePattern.test(item);
    });
    if (!valid) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '登录信息解不开');
    return record as Record<K, string>;
  }

  private signedIn(accountId: string, username: string, now: Date): dtos.AccountSignedInDto {
    return { accountId, username, serverTime: now.getTime() };
  }

  async register(deviceId: string, ip: string, body: dtos.AccountCredentialBodyDto): Promise<dtos.AccountSignedInDto> {
    await this.limit('account_register_device', deviceId, accountRegisterPerDevicePerHour, 3600, '注册过于频繁');
    await this.limit('account_register_source', rateSubjectOf(ip), accountRegisterPerSourcePerHour, 3600, '注册过于频繁');
    const secrets = this.secretsOf(body.sealed, deviceId, ['password', 'recoveryCode'] as const);
    const username = body.username.toLowerCase();
    if ((await this.accounts.credentialsOf(username)) !== null) throw new RelayError(RelayCode.usernameTaken, HttpStatus.CONFLICT, '用户名已被占用');
    const [passwordHash, recoveryHash] = [await this.keys.hash(secrets.password), await this.keys.hash(secrets.recoveryCode)];
    await this.devices.enroll(deviceId, body.signPublicKey, body.boxPublicKey);
    const now = new Date();
    const accountId = await this.accounts.register(username, passwordHash, recoveryHash, deviceId, now);
    if (accountId === null) throw new RelayError(RelayCode.usernameTaken, HttpStatus.CONFLICT, '用户名已被占用');
    this.logger.log(`[Account] action=register deviceId=${deviceId}`);
    return this.signedIn(accountId, username, now);
  }

  // 登录与用恢复码重设共用的限流：先按来源，再按「用户名 + 来源」、按用户名（见 relay_limits.ts）。
  private async credentialLimits(scope: string, username: string, ip: string) {
    const source = rateSubjectOf(ip);
    await this.limit(`${scope}_source`, source, accountLoginPerSourcePerHour, 3600, '尝试过于频繁');
    await this.limit(`${scope}_user_source`, `${username}\n${source}`, accountLoginPerUserSourcePerHour, 3600, '这个用户名尝试过于频繁');
    await this.limit(`${scope}_user`, username, accountLoginPerUserPerHour, 3600, '这个用户名尝试过于频繁');
  }

  private invalid(): never {
    throw new RelayError(RelayCode.credentialsInvalid, HttpStatus.FORBIDDEN, '用户名或密码不对');
  }

  async login(deviceId: string, ip: string, body: dtos.AccountCredentialBodyDto): Promise<dtos.AccountSignedInDto> {
    const username = body.username.toLowerCase();
    await this.credentialLimits('account_login', username, ip);
    const secrets = this.secretsOf(body.sealed, deviceId, ['password'] as const);
    const credentials = await this.accounts.credentialsOf(username);
    if (credentials === null || !(await this.keys.verify(secrets.password, credentials.passwordHash))) this.invalid();
    await this.devices.enroll(deviceId, body.signPublicKey, body.boxPublicKey);
    const now = new Date();
    if (!(await this.accounts.link(credentials.accountId, deviceId, now))) this.invalid();
    this.logger.log(`[Account] action=login deviceId=${deviceId}`);
    return this.signedIn(credentials.accountId, username, now);
  }

  // 忘了密码：凭恢复码设新密码，旧恢复码同时作废、换成客户端新生成的那个；登录这台设备，账号下别的设备都下线（拿着旧密码登录的设备不能留着，人工决策见类上方）。
  async recover(deviceId: string, ip: string, body: dtos.AccountCredentialBodyDto): Promise<dtos.AccountSignedInDto> {
    const username = body.username.toLowerCase();
    await this.credentialLimits('account_recover', username, ip);
    const secrets = this.secretsOf(body.sealed, deviceId, ['recoveryCode', 'password', 'newRecoveryCode'] as const);
    const credentials = await this.accounts.credentialsOf(username);
    if (credentials === null || !(await this.keys.verify(secrets.recoveryCode, credentials.recoveryHash))) this.invalid();
    const [passwordHash, recoveryHash] = [await this.keys.hash(secrets.password), await this.keys.hash(secrets.newRecoveryCode)];
    const now = new Date();
    if (!(await this.accounts.updateSecrets(credentials.accountId, { passwordHash, recoveryHash }, now))) this.invalid();
    await this.devices.enroll(deviceId, body.signPublicKey, body.boxPublicKey);
    if (!(await this.accounts.link(credentials.accountId, deviceId, now, true))) this.invalid();
    this.logger.log(`[Account] action=recover deviceId=${deviceId}`);
    return this.signedIn(credentials.accountId, username, now);
  }

  // 登录着的设备直接改密码或换恢复码（不要旧密码：忘了密码时在还登着的手机上重设，用户选定）。
  async changeSecret(deviceId: string, kind: 'password' | 'recoveryCode', body: dtos.AccountSecretBodyDto) {
    await this.limit('account_secret_change', deviceId, accountSecretChangePerDevicePerHour, 3600, '修改过于频繁');
    const accountId = await this.accountOrMissing(deviceId);
    const secret = this.secretsOf(body.sealed, deviceId, [kind] as const)[kind];
    const hashed = await this.keys.hash(secret);
    if (!(await this.accounts.updateSecrets(accountId, kind === 'password' ? { passwordHash: hashed } : { recoveryHash: hashed }, new Date()))) {
      throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    }
    this.logger.log(`[Account] action=change_${kind === 'password' ? 'password' : 'recovery'} deviceId=${deviceId}`);
  }

  // 扫码登录，新设备这一侧：登记设备密钥、发一张 5 分钟的票据（放进二维码，另带 6 位核对码两边都显示）。
  // 还没登记过的设备另按来源计数（每次换新密钥就能绕过按设备的计数，每次都会多登记一台设备）。
  // 票据另记这台自报的机型与按来源 IP 在本机离线库查出的属地（src/common/ip_region.ts），给批准方核对；IP 原文不进票据、不进日志。
  async startJoin(deviceId: string, ip: string, body: dtos.AccountJoinStartBodyDto): Promise<dtos.AccountJoinDto> {
    await this.limit('account_join', deviceId, accountJoinPerDevicePerHour, 3600, '出示二维码过于频繁');
    if (!(await this.devices.registered(deviceId))) await this.limit('account_join_source', rateSubjectOf(ip), accountJoinPerSourcePerHour, 3600, '出示二维码过于频繁');
    await this.devices.enroll(deviceId, body.signPublicKey, body.boxPublicKey);
    const ticketId = randomBytes(16).toString('base64url');
    const code = String(randomInt(1_000_000)).padStart(6, '0');
    const ticket: JoinTicket = { deviceId, code, accountId: null, device: body.device ?? null, region: await this.regions.regionOf(ip) };
    await this.redis.set(RedisKeys.accountJoin(ticketId), JSON.stringify(ticket), 'EX', RedisKeyTTL.accountJoin);
    return { ticketId, code, expiresAt: Date.now() + RedisKeyTTL.accountJoin * 1000 };
  }

  // 已登录的设备批准：核对码对得上才把新设备登记进自己的账号。先占住票据再登记（比对原值后改写，原子完成），
  // 两个账号同时或先后来批只有先占到的那个算数，后来的回 JOIN_NOT_FOUND；同一个账号重发照旧算成功。
  async approveJoin(deviceId: string, ticketId: string, code: string) {
    await this.limit('account_approve', deviceId, accountApprovePerDevicePerHour, 3600, '批准过于频繁');
    const key = RedisKeys.accountJoin(ticketId);
    const raw = await this.redis.get(key);
    const ticket = raw === null ? null : (JSON.parse(raw) as JoinTicket);
    const notFound = () => new RelayError(RelayCode.joinNotFound, HttpStatus.NOT_FOUND, '二维码已过期或不对');
    if (raw === null || ticket === null || !sameText(ticket.code, code) || ticket.deviceId === deviceId) throw notFound();
    const accountId = await this.accountOrMissing(deviceId);
    const claimed = ticket.accountId === null && (await this.redis.eval(claimJoinScript, 1, key, raw, JSON.stringify({ ...ticket, accountId }))) !== null;
    if (!claimed && (await this.ticketOf(ticketId))?.accountId !== accountId) throw notFound();
    if (claimed && !(await this.accounts.link(accountId, ticket.deviceId, new Date()))) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    this.logger.log(`[Account] action=approve_join deviceId=${deviceId} joined=${ticket.deviceId} claimed=${claimed}`);
  }

  // 批准方扫到二维码、核对码对得上时，批准之前先看请求方的机型与属地（同批准的限流与核对；已被别的账号批准的不给看）。
  async inspectJoin(deviceId: string, ticketId: string, code: string): Promise<dtos.AccountJoinRequestDto> {
    await this.limit('account_inspect', deviceId, accountApprovePerDevicePerHour, 3600, '查看过于频繁');
    const ticket = await this.ticketOf(ticketId);
    if (ticket === null || !sameText(ticket.code, code) || ticket.deviceId === deviceId) throw new RelayError(RelayCode.joinNotFound, HttpStatus.NOT_FOUND, '二维码已过期或不对');
    const accountId = await this.accountOrMissing(deviceId);
    if (ticket.accountId !== null && ticket.accountId !== accountId) throw new RelayError(RelayCode.joinNotFound, HttpStatus.NOT_FOUND, '二维码已过期或不对');
    return { device: ticket.device ?? null, region: ticket.region ?? null };
  }

  // 新设备离开出示页：作废自己还没被批准的票据（比对原值后删除，原子完成，不和批准抢）；别的设备的、已批准的、已过期的什么也不做。
  async cancelJoin(deviceId: string, ticketId: string) {
    const key = RedisKeys.accountJoin(ticketId);
    const raw = await this.redis.get(key);
    const ticket = raw === null ? null : (JSON.parse(raw) as JoinTicket);
    if (raw === null || ticket === null || ticket.deviceId !== deviceId || ticket.accountId !== null) return;
    const removed = await this.redis.eval(cancelJoinScript, 1, key, raw);
    this.logger.log(`[Account] action=cancel_join deviceId=${deviceId} removed=${removed === 1}`);
  }

  // 新设备轮询：批准了就带上账号（重复问照旧给，票据到期自然删）。
  async joinState(deviceId: string, ticketId: string): Promise<dtos.AccountJoinStateDto> {
    const ticket = await this.ticketOf(ticketId);
    if (ticket === null || ticket.deviceId !== deviceId) throw new RelayError(RelayCode.joinNotFound, HttpStatus.NOT_FOUND, '二维码已过期');
    if (ticket.accountId === null) return { state: 'pending', account: null };
    const summary = await this.accounts.summaryOf(deviceId, new Date());
    if (summary === null) throw new RelayError(RelayCode.joinNotFound, HttpStatus.NOT_FOUND, '二维码已过期');
    return { state: 'approved', account: this.signedIn(summary.accountId, summary.username, new Date()) };
  }

  private async ticketOf(ticketId: string): Promise<JoinTicket | null> {
    const raw = await this.redis.get(RedisKeys.accountJoin(ticketId));
    return raw === null ? null : (JSON.parse(raw) as JoinTicket);
  }

  async summary(deviceId: string): Promise<dtos.AccountSummaryDto> {
    const summary = (await this.accounts.summaryOf(deviceId, new Date())) ?? (await this.missing(deviceId));
    return { accountId: summary.accountId, username: summary.username, deviceCount: summary.deviceCount, createdAt: summary.createTime.getTime() };
  }

  // 注销：账号下全部密钥记墓碑（见 missing），再删登记、账号下的数据与账号本身，同一事务。
  async remove(deviceId: string) {
    if (!(await this.accounts.deleteOf(deviceId))) await this.missing(deviceId);
    this.logger.log(`[Account] action=delete deviceId=${deviceId}`);
  }
}

// device 与 region 是 11-16 起加的（之前出示的票据没有，5 分钟内就过期了）。
type JoinTicket = { deviceId: string; code: string; accountId: string | null; device?: string | null; region?: string | null };

// 占住扫码登录的票据：值还是读到的那一串才改写成带账号号的（保留过期时间），否则返回空。
const claimJoinScript = `if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('SET', KEYS[1], ARGV[2], 'KEEPTTL') end
return false`;

// 作废扫码登录的票据：值还是读到的那一串（没被批准）才删。
const cancelJoinScript = `if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end
return 0`;

const sameText = (left: string, right: string) => left.length === right.length && timingSafeEqual(Buffer.from(left), Buffer.from(right));
