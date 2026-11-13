import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';

import { rateSubjectOf } from 'src/common/client_ip';
import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { accountSignInPerDevicePerHour, accountSignInPerHour, accountSignInPerSourcePerHour } from 'src/common/relay_limits';
import { AccountRepository } from 'src/modules/account/account.repository';
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
  ) {
    this.providers = new Map(providers.map((provider) => [provider.name, provider]));
  }

  // 用一种登录方式登录：核对通过后登记这把设备密钥（自签名，请求体带两把公钥）并登录到对应账号，没有账号就新建。
  async signIn(deviceId: string, ip: string, providerName: string, body: dtos.AccountSignInBodyDto & ProviderSignIn): Promise<dtos.AccountSignInDto> {
    const provider = this.providers.get(providerName);
    if (provider === undefined) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '不支持的登录方式');
    // 先按设备、来源与全局限流（每次都要代登录学校教务，见 relay_limits.ts）；按学号的那一档在登录方式里。
    for (const [scope, subject, limit] of [
      ['account_sign_in_device', deviceId, accountSignInPerDevicePerHour],
      ['account_sign_in_source', rateSubjectOf(ip), accountSignInPerSourcePerHour],
      ['account_sign_in', 'all', accountSignInPerHour],
    ] as const) {
      const retryAfter = await this.limiter.hit(scope, subject, limit, 3600);
      if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '登录过于频繁', { retryAfter });
    }
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
    return { accountId: summary.accountId, providers: summary.providers, deviceCount: summary.deviceCount, createdAt: summary.createTime.getTime() };
  }

  async remove(deviceId: string) {
    if (!(await this.accounts.deleteOf(deviceId))) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    this.logger.log(`[Account] action=delete deviceId=${deviceId}`);
  }
}
