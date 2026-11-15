import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import Redis from 'ioredis';
import { randomBytes, randomInt, timingSafeEqual } from 'node:crypto';

import { rateSubjectOf } from 'src/common/client_ip';
import { RateLimiter, REDIS } from 'src/common/redis/redis.module';
import { RedisKeys, RedisKeyTTL } from 'src/common/redis/redis_keys';
import { RelayCode, RelayError } from 'src/common/relay_error';
import {
  accountApprovePerDevicePerHour,
  accountJoinPerDevicePerHour,
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
@Injectable()
export class AccountService {
  private readonly logger = new Logger('Account');

  constructor(
    private readonly accounts: AccountRepository,
    private readonly keys: AccountKeys,
    private readonly devices: DeviceService,
    private readonly limiter: RateLimiter,
    @Inject(REDIS) private readonly redis: Redis,
  ) {}

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

  // 忘了密码：凭恢复码设新密码，旧恢复码同时作废、换成客户端新生成的那个；登录这台设备。
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
    if (!(await this.accounts.link(credentials.accountId, deviceId, now))) this.invalid();
    this.logger.log(`[Account] action=recover deviceId=${deviceId}`);
    return this.signedIn(credentials.accountId, username, now);
  }

  // 登录着的设备直接改密码或换恢复码（不要旧密码：忘了密码时在还登着的手机上重设，用户选定）。
  async changeSecret(deviceId: string, kind: 'password' | 'recoveryCode', body: dtos.AccountSecretBodyDto) {
    await this.limit('account_secret_change', deviceId, accountSecretChangePerDevicePerHour, 3600, '修改过于频繁');
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    const secret = this.secretsOf(body.sealed, deviceId, [kind] as const)[kind];
    const hashed = await this.keys.hash(secret);
    if (!(await this.accounts.updateSecrets(accountId, kind === 'password' ? { passwordHash: hashed } : { recoveryHash: hashed }, new Date()))) {
      throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    }
    this.logger.log(`[Account] action=change_${kind === 'password' ? 'password' : 'recovery'} deviceId=${deviceId}`);
  }

  // 扫码登录，新设备这一侧：登记设备密钥、发一张 5 分钟的票据（放进二维码，另带 6 位核对码两边都显示）。
  async startJoin(deviceId: string, body: dtos.AccountDeviceKeysDto): Promise<dtos.AccountJoinDto> {
    await this.limit('account_join', deviceId, accountJoinPerDevicePerHour, 3600, '出示二维码过于频繁');
    await this.devices.enroll(deviceId, body.signPublicKey, body.boxPublicKey);
    const ticketId = randomBytes(16).toString('base64url');
    const code = String(randomInt(1_000_000)).padStart(6, '0');
    const ticket: JoinTicket = { deviceId, code, accountId: null };
    await this.redis.set(RedisKeys.accountJoin(ticketId), JSON.stringify(ticket), 'EX', RedisKeyTTL.accountJoin);
    return { ticketId, code, expiresAt: Date.now() + RedisKeyTTL.accountJoin * 1000 };
  }

  // 已登录的设备批准：核对码对得上才把新设备登记进自己的账号。
  async approveJoin(deviceId: string, ticketId: string, code: string) {
    await this.limit('account_approve', deviceId, accountApprovePerDevicePerHour, 3600, '批准过于频繁');
    const key = RedisKeys.accountJoin(ticketId);
    const ticket = await this.ticketOf(ticketId);
    if (ticket === null || !sameText(ticket.code, code) || ticket.deviceId === deviceId) throw new RelayError(RelayCode.joinNotFound, HttpStatus.NOT_FOUND, '二维码已过期或不对');
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    if (ticket.accountId === null) {
      if (!(await this.accounts.link(accountId, ticket.deviceId, new Date()))) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
      await this.redis.set(key, JSON.stringify({ ...ticket, accountId }), 'KEEPTTL');
    }
    this.logger.log(`[Account] action=approve_join deviceId=${deviceId} joined=${ticket.deviceId}`);
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
    const summary = await this.accounts.summaryOf(deviceId, new Date());
    if (summary === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    return { accountId: summary.accountId, username: summary.username, deviceCount: summary.deviceCount, createdAt: summary.createTime.getTime() };
  }

  async remove(deviceId: string) {
    if (!(await this.accounts.deleteOf(deviceId))) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    this.logger.log(`[Account] action=delete deviceId=${deviceId}`);
  }
}

type JoinTicket = { deviceId: string; code: string; accountId: string | null };

const sameText = (left: string, right: string) => left.length === right.length && timingSafeEqual(Buffer.from(left), Buffer.from(right));
