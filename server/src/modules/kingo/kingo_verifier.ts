import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import Redis from 'ioredis';
import { randomBytes } from 'node:crypto';

import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys, RedisKeyTTL } from 'src/common/redis/redis_keys';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { kingoConcurrentPerInstance, kingoRequestTimeoutMs, kingoResponseMaxBytes, kingoSignInDeadlineMs } from 'src/common/relay_limits';
import { buildLoginPlain, encryptLoginParams, KingoCredential, loginToken } from 'src/modules/kingo/kingo_codec';

// 学号哈希里的教务来源：同客户端的账号身份（lib/edu/kingo_client.dart 的 kingoBase），不随测试里的 RELAY_KINGO_BASE 变。
export const kingoSource = 'http://42.247.18.146';
// 同客户端 kingoUserAgent，教务看到的是同一种浏览器。
const userAgent = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36';

export type KingoStep = { kind: 'verified'; loginId: string } | { kind: 'captcha'; challengeId: string; image: string; contentType: string; hint: string };

// 代登录教务的端口：只负责登录一次、读身份页拿学号，不知道应用账号。出错一律抛 RelayError（ACCOUNT_REJECTED、UPSTREAM_UNAVAILABLE、CAPTCHA_EXPIRED）。
export abstract class KingoVerifier {
  abstract start(deviceId: string, credential: KingoCredential): Promise<KingoStep>;
  abstract answer(deviceId: string, challengeId: string, credential: KingoCredential, captcha: string): Promise<KingoStep>;
}

type KingoResponse = { status: number; location: string; contentType: string; bytes: Buffer; body: string };

const upstream = (reason: 'network' | 'timeout' | 'rateLimited' | 'http' | 'format', message: string) =>
  new RelayError(RelayCode.upstreamUnavailable, reason === 'rateLimited' ? HttpStatus.TOO_MANY_REQUESTS : HttpStatus.BAD_GATEWAY, message, { reason });

// 一次登录的教务会话：cookie 罐与页面会话号，同客户端 KingoClient；不跟随重定向，只认同源。
class KingoSession {
  constructor(
    readonly base: string,
    readonly deadline: AbortSignal,
    readonly jar: Record<string, string> = {},
    public pageSession = '',
  ) {}

  async send(method: 'GET' | 'POST', path: string, options: { referer?: string; accept?: string; body?: string; binary?: boolean } = {}): Promise<KingoResponse> {
    const url = new URL(path, this.base);
    if (url.origin !== new URL(this.base).origin) throw upstream('format', '教务返回了非同源地址');
    const cookie = Object.entries(this.jar).map(([name, value]) => `${name}=${value}`).join('; ');
    let response: Response;
    try {
      response = await fetch(url, {
        method,
        redirect: 'manual',
        signal: AbortSignal.any([AbortSignal.timeout(kingoRequestTimeoutMs), this.deadline]),
        headers: {
          'User-Agent': userAgent,
          Accept: options.accept ?? 'text/plain, */*; q=0.01',
          ...(cookie === '' ? {} : { Cookie: cookie }),
          ...(options.referer === undefined ? {} : { Referer: new URL(options.referer, this.base).toString() }),
          ...(options.body === undefined ? {} : { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' }),
        },
        body: options.body,
      });
    } catch (error) {
      if (error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')) throw upstream('timeout', '教务请求超时');
      console.error(error);
      throw upstream('network', '连不上教务');
    }
    const location = response.headers.get('location') ?? '';
    if (response.status >= 300 && response.status < 400 && location.includes('/frame/errors/406')) throw upstream('rateLimited', '教务提示请求太过频繁');
    if (response.status >= 300 && response.status < 400 && location.includes('/cas/login')) throw upstream('format', '教务登录状态丢失');
    if (response.status < 200 || response.status >= 300) throw upstream('http', `教务请求失败（HTTP ${response.status}）`);
    for (const line of response.headers.getSetCookie()) {
      const pair = line.split(';')[0].trim();
      const index = pair.indexOf('=');
      if (index > 0) this.jar[pair.substring(0, index)] = pair.substring(index + 1);
    }
    const bytes = await readLimited(response);
    const contentType = response.headers.get('content-type') ?? '';
    return { status: response.status, location, contentType, bytes, body: options.binary ? '' : decodePage(bytes, contentType) };
  }
}

const readLimited = async (response: Response) => {
  if (Number(response.headers.get('content-length') ?? 0) > kingoResponseMaxBytes) throw upstream('format', '教务响应超过上限');
  const chunks: Buffer[] = [];
  let total = 0;
  try {
    for await (const chunk of response.body ?? []) {
      total += chunk.length;
      if (total > kingoResponseMaxBytes) throw upstream('format', '教务响应超过上限');
      chunks.push(Buffer.from(chunk));
    }
  } catch (error) {
    if (error instanceof RelayError) throw error;
    if (error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')) throw upstream('timeout', '教务请求超时');
    console.error(error);
    throw upstream('network', '教务响应中断');
  }
  return Buffer.concat(chunks);
};

// 同客户端 KingoClient._decode：声明 GB 系字符集用 GBK，否则 UTF-8，UTF-8 解不开回退 GBK。
const decodePage = (bytes: Buffer, contentType: string) => {
  const head = bytes.subarray(0, 1000).toString('latin1');
  const charset = /charset\s*=\s*["']?([\w-]+)/i.exec(`${contentType} ${head}`)?.[1]?.toLowerCase() ?? '';
  if (charset.includes('gb')) return new TextDecoder('gbk').decode(bytes);
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return new TextDecoder('gbk').decode(bytes);
  }
};

// 以下三个同客户端 lib/edu/login_rules.dart 的 captchaRequired、captchaHint、explainLogin（只保留中转要分的几类）。
const splitMessage = (message: unknown) => {
  const raw = message === null || message === undefined ? '' : String(message);
  const bar = raw.indexOf('|');
  const failCount = bar >= 0 ? Number.parseInt(raw.substring(bar + 1), 10) : NaN;
  return { text: bar >= 0 ? raw.substring(0, bar) : raw, failCount: Number.isNaN(failCount) ? null : failCount };
};

const captchaRequired = (status: string, message: unknown) => {
  if (status === '200') return false;
  const { text, failCount } = splitMessage(message);
  return status === '401' || text.includes('验证码') || (failCount !== null && failCount >= 2);
};

const captchaHint = (status: string, message: unknown) => {
  const { text } = splitMessage(message);
  if (status === '401' || text.includes('验证码')) return '验证码不正确，请重新输入';
  return text === '' ? '请输入图中的验证码' : text.slice(0, 200);
};

const rejected = (status: string, message: unknown, rawBody: string): RelayError => {
  const { text, failCount } = splitMessage(message);
  if (text === '' && rawBody.trim() === '') return upstream('format', '教务没有返回登录结果');
  const reject = (reason: string, fallback: string) =>
    new RelayError(RelayCode.accountRejected, HttpStatus.UNPROCESSABLE_ENTITY, fallback, { reason, message: (text === '' ? fallback : text).slice(0, 200), failCount });
  if (status === '505' || text.includes('短信')) return reject('smsRequired', '教务要求先完成短信验证才能登录');
  if (text.includes('已输错')) return reject('passwordWrongCount', '密码错误次数过多');
  if (text.includes('锁定')) return reject('accountLocked', '账号已锁定');
  if (text.includes('账号或密码')) return reject('passwordWrong', '账号或密码不正确');
  if (status === '407' || status === '410') return reject('accountState', '账号状态异常，教务拒绝登录');
  return reject('loginFailed', '登录失败');
};

@Injectable()
export class HttpKingoVerifier extends KingoVerifier {
  private readonly logger = new Logger('KingoVerifier');
  private running = 0;

  constructor(@Inject(REDIS) private readonly redis: Redis) {
    super();
  }

  start(deviceId: string, credential: KingoCredential) {
    return this.guarded(async (deadline) => {
      const session = new KingoSession(env().account.kingoBase, deadline);
      const page = await session.send('GET', '/cas/login.action');
      session.pageSession = /_ssessionid\s*=\s*"([^"]+)"/.exec(page.body)?.[1] ?? session.jar['JSESSIONID'] ?? '';
      if (session.pageSession === '') throw upstream('format', '教务登录页没有会话');
      return this.attempt(deviceId, session, credential, '');
    });
  }

  answer(deviceId: string, challengeId: string, credential: KingoCredential, captcha: string) {
    return this.guarded(async (deadline) => {
      const raw = await this.redis.getdel(RedisKeys.kingoChallenge(challengeId));
      const saved = raw === null ? null : (JSON.parse(raw) as { deviceId: string; jar: Record<string, string>; pageSession: string });
      if (saved === null || saved.deviceId !== deviceId) throw new RelayError(RelayCode.captchaExpired, HttpStatus.GONE, '验证码已过期，请重新登录');
      return this.attempt(deviceId, new KingoSession(env().account.kingoBase, deadline, saved.jar, saved.pageSession), credential, captcha);
    });
  }

  // 每个实例同时最多 kingoConcurrentPerInstance 个代登录，整次有总时限。
  private async guarded(run: (deadline: AbortSignal) => Promise<KingoStep>) {
    if (this.running >= kingoConcurrentPerInstance) throw new RelayError(RelayCode.rateLimited, HttpStatus.SERVICE_UNAVAILABLE, '登录的人太多，请稍后再试', { retryAfter: 10 });
    this.running++;
    try {
      return await run(AbortSignal.timeout(kingoSignInDeadlineMs));
    } finally {
      this.running--;
    }
  }

  // 同客户端 KingoClient.login 的第 2 到 4 步：取临时密钥与时间戳、提交、要验证码时取图，成功后读身份页。
  private async attempt(deviceId: string, session: KingoSession, credential: KingoCredential, captcha: string): Promise<KingoStep> {
    const rand = `${Date.now()}000`;
    await session.send('GET', `/custom/js/GetKingoEncypt.jsp?random=${rand}`, { referer: '/cas/login.action' });
    await session.send('GET', `/custom/js/SetKingoEncypt.jsp?random=${rand}`, { referer: '/cas/login.action' });
    const deskey = (await session.send('GET', '/frame/homepage?method=getTempDeskey', { referer: '/cas/login.action' })).body.trim();
    const timestamp = (await session.send('GET', '/frame/homepage?method=getTempNowtime', { referer: '/cas/login.action' })).body.trim();
    if (deskey === '' || timestamp === '') throw upstream('format', '教务临时密钥或时间戳为空');
    const plain = buildLoginPlain(credential, session.pageSession, captcha);
    const body = `params=${encryptLoginParams(plain, deskey)}&token=${loginToken(plain, timestamp)}&timestamp=${timestamp}&deskey=&ssessionid=${session.pageSession}`;
    const posted = await session.send('POST', '/cas/logon.action', { referer: '/cas/login.action', accept: 'text/html, */*; q=0.01', body });
    type LogonResult = { status?: unknown; message?: unknown; result?: unknown };
    let data: LogonResult | null = null;
    try {
      const parsed: unknown = JSON.parse(posted.body);
      data = typeof parsed === 'object' && parsed !== null ? (parsed as LogonResult) : null;
    } catch {
      data = null;
    }
    const status = data?.status === undefined || data.status === null ? '' : String(data.status);
    if (captchaRequired(status, data?.message)) {
      const image = await session.send('GET', `/cas/genValidateCode?v=${(Date.now() % 100) + 1}`, { accept: 'image/jpeg,image/*', binary: true });
      const challengeId = randomBytes(16).toString('base64url');
      await this.redis.set(RedisKeys.kingoChallenge(challengeId), JSON.stringify({ deviceId, jar: session.jar, pageSession: session.pageSession }), 'EX', RedisKeyTTL.kingoChallenge);
      this.logger.log(`[KingoVerifier] action=captcha deviceId=${deviceId} retry=${captcha !== ''}`);
      // 第一次要验证码时还没填过，不说「不正确」；因输错次数要的照样把教务的提示给用户。
      const hint = captchaHint(status, data?.message);
      return { kind: 'captcha', challengeId, image: image.bytes.toString('base64'), contentType: (image.contentType || 'image/jpeg').split(';')[0], hint: captcha === '' && hint === '验证码不正确，请重新输入' ? '请输入图中的验证码' : hint };
    }
    if (status !== '200') throw rejected(status, data?.message, posted.body);
    if (data?.result === undefined || data.result === null) throw upstream('format', '教务登录结果缺少跳转地址');
    const location = new URL(String(data.result), session.base);
    await session.send('GET', location.pathname + location.search, { referer: '/cas/login.action' });
    const info = await session.send('GET', '/frame/home/js/SetMainInfo.jsp', { referer: location.pathname + location.search });
    const userCode = /G_USER_CODE\s*=\s*'([^']*)'/.exec(info.body)?.[1] ?? '';
    const loginId = (/_loginid\s*=\s*'([^']*)'/.exec(info.body)?.[1] ?? '').trim();
    if (userCode === '' || userCode === 'kingo.guest' || loginId === '') throw upstream('format', '教务身份页格式异常');
    return { kind: 'verified', loginId };
  }
}
