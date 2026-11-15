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
  accountRecoveryDays,
  accountRecoveryListLimit,
  accountRecoveryPerDevicePerDay,
  accountSignInPerDevicePerHour,
  accountSignInPerHour,
  accountSignInPerSourcePerHour,
  accountSignInPerSubjectPerDay,
} from 'src/common/relay_limits';
import { kingoSource } from 'src/modules/kingo/kingo_verifier';
import { AccountRepository, RecoveryRow } from 'src/modules/account/account.repository';
import { AccountKeys } from 'src/modules/account/account_keys';
import { ACCOUNT_PROVIDERS, AccountProvider, ProviderSignIn } from 'src/modules/account/account_provider';
import { DeviceService } from 'src/modules/device/device.service';
import * as dtos from 'src/modules/account/account.dto';

@Injectable()
export class AccountService {
  private readonly logger = new Logger('Account');
  private readonly providers: Map<string, AccountProvider>;

  constructor(
    @Inject(ACCOUNT_PROVIDERS) providers: AccountProvider[],
    private readonly accounts: AccountRepository,
    private readonly keys: AccountKeys,
    private readonly devices: DeviceService,
    private readonly limiter: RateLimiter,
    @Inject(REDIS) private readonly redis: Redis,
  ) {
    this.providers = new Map(providers.map((provider) => [provider.name, provider]));
  }

  private async limit(scope: string, subject: string, limit: number, window: number, message: string) {
    const retryAfter = await this.limiter.hit(scope, subject, limit, window);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, message, { retryAfter });
  }

  private async signInLimits(deviceId: string, ip: string) {
    for (const [scope, subject, limit] of [
      ['account_sign_in_device', deviceId, accountSignInPerDevicePerHour],
      ['account_sign_in_source', rateSubjectOf(ip), accountSignInPerSourcePerHour],
      ['account_sign_in', 'all', accountSignInPerHour],
    ] as const) {
      await this.limit(scope, subject, limit, 3600, '登录过于频繁');
    }
  }

  // 教务学号这个主体（同教务核对的登录方式名与主体，设备核对与以前教务核对过的落到同一个账号）。
  private subjectHashOf(loginId: string) {
    return this.keys.subjectHash('kingo', `${kingoSource}\n${loginId}`);
  }

  // [人工决策-2026-11-15 15:04:27] 应用账号改为设备核对（学校把中转的 IP 整个挡了、确定不会解封，也不加服务器；用户选「设备核对 + 风险规则」，
  // 已有账号必须旧设备扫码授权）：手机自己登录教务（本来就要登），把教务确认的学号报上来，中转不连学校、不收口令摘要，学号照旧只存 HMAC。
  // 服务器验不了手机报的学号（教务是明文 http、不给签名凭证，系统的设备认证在华为手机与全能签上用不了），所以按风险分级：
  // 学号没有账号就新建；已有账号的不能凭设备核对接管，要已登录的设备扫码授权（joins）；按设备、来源、全局与学号限流；节日红包只给建立满 7 天的账号。
  // [人工决策-2026-11-15 15:13:06] 找回（用户选「退出了直接登回，丢了走等待期」）：账号一把设备都没登着（都退出了）时设备核对直接登回；
  // 还有设备登着（丢了手机、重装没退出）就提交找回申请（recoveries），等 3 天，账号的设备打开应用时提醒、可以拒绝或批准，
  // 没人拒绝就生效；同一账号同时有别的设备在申请就都不生效（conflict），免得冒用的人在真主人没设备时抢先。
  async deviceSignIn(deviceId: string, ip: string, body: dtos.AccountDeviceBodyDto): Promise<dtos.AccountDeviceSignInDto> {
    await this.signInLimits(deviceId, ip);
    await this.limit('account_sign_in_subject', this.keys.attemptKey('kingo', body.loginId), accountSignInPerSubjectPerDay, 86400, '这个账号今天尝试登录的次数太多');
    await this.devices.enroll(deviceId, body.signPublicKey, body.boxPublicKey);
    const now = new Date();
    const claimed = await this.accounts.claim('kingo', this.subjectHashOf(body.loginId), deviceId, now);
    this.logger.log(`[Account] action=device_sign_in deviceId=${deviceId} result=${claimed === null ? 'exists' : claimed.created ? 'created' : 'returned'}`);
    if (claimed === null) return { status: 'exists', account: null };
    return { status: 'signedIn', account: { accountId: claimed.accountId, created: claimed.created, serverTime: now.getTime() } };
  }

  // 扫码授权，新设备这一侧：登记设备密钥、发一张 5 分钟的票据（放进二维码，另带 6 位核对码两边都显示）。
  async startJoin(deviceId: string, body: dtos.AccountDeviceBodyDto): Promise<dtos.AccountJoinDto> {
    await this.limit('account_join', deviceId, accountJoinPerDevicePerHour, 3600, '出示二维码过于频繁');
    await this.devices.enroll(deviceId, body.signPublicKey, body.boxPublicKey);
    const ticketId = randomBytes(16).toString('base64url');
    const code = String(randomInt(1_000_000)).padStart(6, '0');
    const ticket: JoinTicket = { deviceId, subjectHash: this.subjectHashOf(body.loginId), code, accountId: null };
    await this.redis.set(RedisKeys.accountJoin(ticketId), JSON.stringify(ticket), 'EX', RedisKeyTTL.accountJoin);
    return { ticketId, code, expiresAt: Date.now() + RedisKeyTTL.accountJoin * 1000 };
  }

  // 已登录的设备批准：核对码对得上、两边是同一个学号的账号，才把新设备登记进来。
  async approveJoin(deviceId: string, ticketId: string, code: string) {
    await this.limit('account_approve', deviceId, accountApprovePerDevicePerHour, 3600, '批准过于频繁');
    const key = RedisKeys.accountJoin(ticketId);
    const ticket = await this.ticketOf(ticketId);
    if (ticket === null || !sameText(ticket.code, code)) throw new RelayError(RelayCode.joinNotFound, HttpStatus.NOT_FOUND, '二维码已过期或不对');
    const mine = await this.accounts.subjectOf(deviceId, 'kingo');
    if (mine === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    if (mine.subjectHash !== ticket.subjectHash || ticket.deviceId === deviceId) throw new RelayError(RelayCode.joinMismatch, HttpStatus.FORBIDDEN, '不是同一个学号的应用账号');
    if (ticket.accountId === null) {
      if (!(await this.accounts.link(mine.accountId, ticket.deviceId, new Date()))) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
      await this.redis.set(key, JSON.stringify({ ...ticket, accountId: mine.accountId }), 'KEEPTTL');
    }
    this.logger.log(`[Account] action=approve_join deviceId=${deviceId} joined=${ticket.deviceId}`);
  }

  // 新设备轮询：批准了就带上账号（重复问照旧给，票据到期自然删）。
  async joinState(deviceId: string, ticketId: string): Promise<dtos.AccountJoinStateDto> {
    const ticket = await this.ticketOf(ticketId);
    if (ticket === null || ticket.deviceId !== deviceId) throw new RelayError(RelayCode.joinNotFound, HttpStatus.NOT_FOUND, '二维码已过期');
    if (ticket.accountId === null) return { state: 'pending', account: null };
    return { state: 'approved', account: { accountId: ticket.accountId, created: false, serverTime: Date.now() } };
  }

  // 提交找回申请（自签名，设备核对之后学号已有账号且还有设备登着时）：同一台设备对同一账号只留一条等待中的。
  async requestRecovery(deviceId: string, ip: string, body: dtos.AccountDeviceBodyDto): Promise<dtos.AccountRecoveryDto> {
    await this.limit('account_recovery', deviceId, accountRecoveryPerDevicePerDay, 86400, '今天申请找回的次数太多');
    await this.limit('account_recovery_source', rateSubjectOf(ip), accountSignInPerSourcePerHour, 3600, '申请找回过于频繁');
    await this.devices.enroll(deviceId, body.signPublicKey, body.boxPublicKey);
    const account = await this.accounts.accountOfSubject('kingo', this.subjectHashOf(body.loginId));
    if (account === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '这个学号还没有应用账号');
    const row = await this.accounts.requestRecovery(account.accountId, deviceId, new Date());
    this.logger.log(`[Account] action=request_recovery deviceId=${deviceId} recoveryId=${row.id}`);
    return this.recoveryView(row);
  }

  // 新设备看自己的申请：到期且没人拒绝就在这时生效。
  async recoveryState(deviceId: string): Promise<dtos.AccountRecoveryDto> {
    const row = await this.accounts.recoveryOfDevice(deviceId);
    if (row === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有找回申请');
    const now = new Date();
    if (row.state === 'pending' && now.getTime() >= grantAtOf(row)) {
      const state = await this.accounts.settleRecovery(row, now);
      this.logger.log(`[Account] action=settle_recovery recoveryId=${row.id} state=${state}`);
      return this.recoveryView({ ...row, state });
    }
    return this.recoveryView(row);
  }

  // 账号的设备拒绝或批准一条找回申请。
  async decideRecovery(deviceId: string, recoveryId: string, approve: boolean) {
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    if (!(await this.accounts.decideRecovery(recoveryId, accountId, approve ? 'granted' : 'denied', new Date()))) throw new RelayError(RelayCode.joinNotFound, HttpStatus.NOT_FOUND, '这条找回申请已经处理过或不存在');
    this.logger.log(`[Account] action=decide_recovery deviceId=${deviceId} recoveryId=${recoveryId} approve=${approve}`);
  }

  private recoveryView(row: RecoveryRow): dtos.AccountRecoveryDto {
    return {
      recoveryId: row.id,
      state: row.state,
      grantAt: grantAtOf(row),
      account: row.state === 'granted' ? { accountId: row.accountId, created: false, serverTime: Date.now() } : null,
    };
  }

  private async ticketOf(ticketId: string): Promise<JoinTicket | null> {
    const raw = await this.redis.get(RedisKeys.accountJoin(ticketId));
    return raw === null ? null : (JSON.parse(raw) as JoinTicket);
  }

  // 用一种登录方式登录：核对通过后登记这把设备密钥（自签名，请求体带两把公钥）并登录到对应账号，没有账号就新建。
  async signIn(deviceId: string, ip: string, providerName: string, body: dtos.AccountSignInBodyDto & ProviderSignIn): Promise<dtos.AccountSignInDto> {
    const provider = this.providers.get(providerName);
    if (provider === undefined) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '不支持的登录方式');
    // 先按设备、来源与全局限流（每次都要代登录学校教务，见 relay_limits.ts）；按学号的那一档在登录方式里。
    await this.signInLimits(deviceId, ip);
    const outcome = await provider.verify(deviceId, body);
    if (outcome.kind === 'captcha') return { status: 'captcha', account: null, captcha: { challengeId: outcome.challengeId, image: outcome.image, contentType: outcome.contentType, hint: outcome.hint } };
    await this.devices.enroll(deviceId, body.signPublicKey, body.boxPublicKey);
    const now = new Date();
    const { accountId, created } = await this.accounts.signIn(provider.name, this.keys.subjectHash(provider.name, outcome.subject), deviceId, now);
    this.logger.log(`[Account] action=sign_in provider=${provider.name} deviceId=${deviceId} created=${created}`);
    return { status: 'signedIn', account: { accountId, created, serverTime: now.getTime() }, captcha: null };
  }

  async summary(deviceId: string): Promise<dtos.AccountSummaryDto> {
    const summary = await this.accounts.summaryOf(deviceId, new Date());
    if (summary === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    const recoveries = await this.accounts.pendingRecoveries(summary.accountId, accountRecoveryListLimit);
    return {
      accountId: summary.accountId,
      providers: summary.providers,
      deviceCount: summary.deviceCount,
      createdAt: summary.createTime.getTime(),
      recoveries: recoveries.map((row) => ({ recoveryId: row.id, createdAt: row.createTime.getTime(), grantAt: grantAtOf(row) })),
    };
  }

  async remove(deviceId: string) {
    if (!(await this.accounts.deleteOf(deviceId))) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    this.logger.log(`[Account] action=delete deviceId=${deviceId}`);
  }
}

type JoinTicket = { deviceId: string; subjectHash: string; code: string; accountId: string | null };

const grantAtOf = (row: RecoveryRow) => row.createTime.getTime() + accountRecoveryDays * 86400_000;

const sameText = (left: string, right: string) => left.length === right.length && timingSafeEqual(Buffer.from(left), Buffer.from(right));
