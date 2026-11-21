// 电影院的境外转发（Cloudflare Worker，部署用同目录 deploy.sh，说明见 server/README.md「电影院的境外转发」）。
// [人工决策-2026-11-21 15:30:18] 用户选「境外转发，直连不通的源才走它」，并在说明了绕过封锁的法律风险后确认照做（客户端见 lib/toolbox/cinema/cinema_rule.dart 的 CinemaRule.forward）：
// 国内连不上的片源站，手机把搜索与选集请求发到这里（原地址放在查询串 u），这里转给片源站、把回复原样带回；播放列表、密钥与视频不经这里。
// 只转白名单里的主机（环境变量 ALLOWED_HOSTS，逗号分隔，跟着签名的片源规则包里标了 forward 的源维护，不进公开仓库）、只转 GET、https、默认端口，
// 跳转也只跟到白名单里的主机（最多 forwardMaxRedirects 次）；整次 forwardTimeoutMs（比客户端的 15 秒短，好让客户端拿到明确的原因），
// 回复上限 forwardMaxBytes（同客户端接口请求的 2MB）；只带过去浏览器标识、来源页与接受类型这几个请求头，不带手机的 IP（片源站看到的是 Cloudflare 的地址）。
// 不保存、不记录（部署配置关掉 observability，console 只有维护者 wrangler tail 时看得到、不落盘）；按 IP 限流（Rate Limiting 绑定 LIMITER，没配时不限）。
// 自己出的错写在回复头 x-forward-error，客户端按直连时的原因归类（超时、回复太大、连不上），别的算转发不可用。

export interface ForwardLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface ForwardEnv {
  ALLOWED_HOSTS: string;
  LIMITER?: ForwardLimiter;
}

export const forwardPath = '/v1/forward';
export const forwardTimeoutMs = 12_000;
export const forwardMaxBytes = 2 * 1024 * 1024;
export const forwardMaxRedirects = 3;
const passedHeaders = ['user-agent', 'referer', 'accept', 'accept-language'];

type ForwardError = 'not_found' | 'method' | 'rate_limited' | 'target' | 'redirect' | 'too_large' | 'timeout' | 'unreachable';

const failure = (status: number, error: ForwardError) => new Response(null, { status, headers: { 'x-forward-error': error, 'cache-control': 'no-store' } });

// 只认白名单里的 https 主机、默认端口、不带账号口令；不合格为 null。
export const forwardTarget = (raw: string | null, allowed: ReadonlySet<string>): URL | null => {
  const url = raw == null ? null : URL.parse(raw);
  return url != null && url.protocol === 'https:' && url.port === '' && url.username === '' && url.password === '' && allowed.has(url.hostname.toLowerCase()) ? url : null;
};

// 边读边数，超过上限就停下（不先把整份读进内存）；超了为 null。
const readCapped = async (body: ReadableStream<Uint8Array> | null, limit: number): Promise<Uint8Array | null> => {
  const bytes = new Uint8Array(limit);
  let size = 0;
  if (body == null) return bytes.subarray(0, 0);
  const reader = body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return bytes.subarray(0, size);
    if (size + value.byteLength > limit) {
      await reader.cancel();
      return null;
    }
    bytes.set(value, size);
    size += value.byteLength;
  }
};

export const handleForward = async (request: Request, env: ForwardEnv, fetcher: typeof fetch = fetch, timeoutMs = forwardTimeoutMs): Promise<Response> => {
  if (new URL(request.url).pathname !== forwardPath) return failure(404, 'not_found');
  if (request.method !== 'GET') return failure(405, 'method');
  if (env.LIMITER != null && !(await env.LIMITER.limit({ key: request.headers.get('cf-connecting-ip') ?? 'unknown' })).success) return failure(429, 'rate_limited');
  const allowed = new Set(env.ALLOWED_HOSTS.split(',').map((host) => host.trim().toLowerCase()).filter((host) => host.length > 0));
  const first = forwardTarget(new URL(request.url).searchParams.get('u'), allowed);
  if (first == null) return failure(403, 'target');
  let target: URL = first;
  const headers = new Headers();
  for (const name of passedHeaders) {
    const value = request.headers.get(name);
    if (value != null) headers.set(name, value);
  }
  const signal = AbortSignal.timeout(timeoutMs);
  try {
    for (let hop = 0; ; hop++) {
      const upstream = await fetcher(target, { method: 'GET', headers, redirect: 'manual', signal });
      const location = upstream.headers.get('location');
      if (upstream.status >= 300 && upstream.status < 400 && location != null) {
        await upstream.body?.cancel();
        const next: URL | null = hop < forwardMaxRedirects ? forwardTarget(new URL(location, target).toString(), allowed) : null;
        if (next == null) return failure(502, 'redirect');
        target = next;
        continue;
      }
      if (Number(upstream.headers.get('content-length')) > forwardMaxBytes) {
        await upstream.body?.cancel();
        return failure(502, 'too_large');
      }
      const body = await readCapped(upstream.body, forwardMaxBytes);
      if (body == null) return failure(502, 'too_large');
      const replyHeaders = new Headers({ 'cache-control': 'no-store' });
      const type = upstream.headers.get('content-type');
      if (type != null) replyHeaders.set('content-type', type);
      return new Response(body, { status: upstream.status, headers: replyHeaders });
    }
  } catch (error) {
    console.error(error);
    return signal.aborted ? failure(504, 'timeout') : failure(502, 'unreachable');
  }
};

export default { fetch: (request: Request, env: ForwardEnv) => handleForward(request, env) };
