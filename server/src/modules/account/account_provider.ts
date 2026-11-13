import { HttpStatus, Injectable } from '@nestjs/common';

import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { accountSignInPerSubjectPerDay } from 'src/common/relay_limits';
import { decodeBase64url } from 'src/common/crypto/relay_crypto';
import { AccountKeys } from 'src/modules/account/account_keys';
import { KingoCredential } from 'src/modules/kingo/kingo_codec';
import { KingoVerifier, kingoSource } from 'src/modules/kingo/kingo_verifier';

export type ProviderSignIn = { sealed: string; challengeId?: string; captcha?: string };

// 一种登录方式核对的结果：核对通过给出主体（账号体系只拿它算哈希），或要用户再答一步（验证码）。
export type ProviderOutcome = { kind: 'verified'; subject: string } | { kind: 'captcha'; challengeId: string; image: string; contentType: string; hint: string };

// [人工决策-2026-11-13 22:06:22] 登录方式做成可替换的端口（用户选「服务器代登录一次，同时留好后路」）：账号体系只认 provider 名与主体，
// 不知道怎么核对。学校封了中转的 IP、有了官方统一认证、或者改用设备账号时，只换或新增这里的实现，账号、灰度与以后的积分都不动。
// 教务的做法与原因见客户端 lib/domain/app_account.dart：客户端交加密的口令摘要，中转登录一次读身份页取学号，用完即丢，不落库不进日志。
export abstract class AccountProvider {
  abstract readonly name: string;
  abstract verify(deviceId: string, input: ProviderSignIn): Promise<ProviderOutcome>;
}

// 全部登录方式（模块里按名字登记），接口 /v1/account/sign-in/:provider 按名字分发。
export const ACCOUNT_PROVIDERS = Symbol('ACCOUNT_PROVIDERS');

const credentialRules: Record<keyof KingoCredential, RegExp> = {
  account: /^[A-Za-z0-9]{1,32}$/,
  passwordDigest: /^[0-9a-f]{32}$/,
  expression: /^\d{1,2}$/,
  length: /^\d{1,3}$/,
  userzh: /^[01]$/,
  policy: /^[01]$/,
};

// 打开的信封是外部输入：逐项校验，多一项少一项都不认。
const credentialOf = (plain: Buffer | null): KingoCredential | null => {
  if (plain === null) return null;
  let value: unknown;
  try {
    value = JSON.parse(plain.toString('utf8'));
  } catch {
    return null;
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const names = Object.keys(credentialRules) as (keyof KingoCredential)[];
  if (Object.keys(record).length !== names.length) return null;
  for (const name of names) {
    const item = record[name];
    if (typeof item !== 'string' || !credentialRules[name].test(item)) return null;
  }
  return record as KingoCredential;
};

@Injectable()
export class KingoAccountProvider extends AccountProvider {
  readonly name = 'kingo';

  constructor(
    private readonly keys: AccountKeys,
    private readonly verifier: KingoVerifier,
    private readonly limiter: RateLimiter,
  ) {
    super();
  }

  async verify(deviceId: string, input: ProviderSignIn): Promise<ProviderOutcome> {
    const sealed = decodeBase64url(input.sealed);
    const credential = credentialOf(sealed === null ? null : this.keys.open(sealed, deviceId));
    if (credential === null) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '登录信息解不开');
    // 按学号每天最多 accountSignInPerSubjectPerDay 次尝试（含验证码重试）：挡住拿中转去试同学的密码。
    const retryAfter = await this.limiter.hit('account_sign_in_subject', this.keys.attemptKey(this.name, credential.account), accountSignInPerSubjectPerDay, 86400);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '这个账号今天尝试登录的次数太多', { retryAfter });
    const step = input.challengeId === undefined ? await this.verifier.start(deviceId, credential) : await this.verifier.answer(deviceId, input.challengeId, credential, input.captcha ?? '');
    return step.kind === 'verified' ? { kind: 'verified', subject: `${kingoSource}\n${step.loginId}` } : step;
  }
}
