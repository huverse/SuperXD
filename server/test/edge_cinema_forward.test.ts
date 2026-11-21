import worker, { forwardMaxBytes, forwardMaxRedirects, handleForward } from '../edge/cinema_forward';

// 电影院的境外转发（人工决策见 edge/cinema_forward.ts 文件头）：只转白名单主机的 GET、跳转也只跟白名单、回复上限与超时、
// 只带过去几个请求头、自己出的错写在回复头 x-forward-error。全部用假的上游，不连真实站点。

const env = { ALLOWED_HOSTS: 'api.example.com, Other.example.com' };
const ask = (target: string, init: RequestInit = {}) => new Request(`https://edge.example.net/v1/forward?u=${encodeURIComponent(target)}`, init);

const recorder = (reply: () => Response) => {
  const seen: Request[] = [];
  const fetcher: typeof fetch = async (input, init) => {
    seen.push(new Request(input, init));
    return reply();
  };
  return { seen, fetcher };
};

describe('电影院的境外转发', () => {
  beforeEach(() => {
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
  });
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('转白名单主机的 GET：原样带回状态与内容类型，只带过去浏览器标识等几个头，不带手机的地址与 cookie', async () => {
    const { seen, fetcher } = recorder(() => new Response('{"list":[]}', { status: 200, headers: { 'content-type': 'text/html', 'set-cookie': 'a=1' } }));
    const reply = await handleForward(
      ask('https://api.example.com/api.php?ac=detail&wd=合成', { headers: { 'user-agent': 'UA', accept: 'application/json', 'cf-connecting-ip': '203.0.113.9', 'x-forwarded-for': '203.0.113.9', cookie: 'x=1' } }),
      env,
      fetcher,
    );
    expect(reply.status).toBe(200);
    expect(await reply.text()).toBe('{"list":[]}');
    expect([reply.headers.get('content-type'), reply.headers.get('set-cookie'), reply.headers.get('x-forward-error')]).toEqual(['text/html', null, null]);
    expect(new URL(seen[0].url).searchParams.get('wd')).toBe('合成');
    expect([...seen[0].headers.keys()].sort()).toEqual(['accept', 'user-agent']);
    // 白名单不分大小写，上游的错误状态原样带回（不是转发自己的错）。
    const failed = await handleForward(ask('https://other.example.com/x'), env, recorder(() => new Response('busy', { status: 503 })).fetcher);
    expect([failed.status, failed.headers.get('x-forward-error')]).toEqual([503, null]);
  });

  it('不转：白名单外的主机、http、非默认端口、带账号口令、没给地址、不是 GET、别的路径', async () => {
    const { seen, fetcher } = recorder(() => new Response('ok'));
    for (const target of ['https://evil.example.com/x', 'http://api.example.com/x', 'https://api.example.com:8443/x', 'https://user:pass@api.example.com/x', 'not a url']) {
      const reply = await handleForward(ask(target), env, fetcher);
      expect([target, reply.status, reply.headers.get('x-forward-error')]).toEqual([target, 403, 'target']);
    }
    expect((await handleForward(new Request('https://edge.example.net/v1/forward'), env, fetcher)).headers.get('x-forward-error')).toBe('target');
    expect((await handleForward(ask('https://api.example.com/x', { method: 'POST', body: 'a' }), env, fetcher)).headers.get('x-forward-error')).toBe('method');
    expect((await handleForward(new Request('https://edge.example.net/other?u=https%3A%2F%2Fapi.example.com%2F'), env, fetcher)).headers.get('x-forward-error')).toBe('not_found');
    expect(seen).toHaveLength(0);
  });

  it('跳转只跟到白名单里的主机、最多几次；跳到别处或跳太多算转发出错', async () => {
    let hops = 0;
    const chain: typeof fetch = async (input) => {
      hops++;
      const url = new URL(input instanceof Request ? input.url : input.toString());
      if (url.pathname === '/away') return new Response(null, { status: 302, headers: { location: 'https://evil.example.com/' } });
      if (url.pathname === '/loop') return new Response(null, { status: 302, headers: { location: '/loop' } });
      if (url.pathname === '/hop') return new Response(null, { status: 301, headers: { location: 'https://other.example.com/end' } });
      return new Response(url.host);
    };
    const followed = await handleForward(ask('https://api.example.com/hop'), env, chain);
    expect([followed.status, await followed.text()]).toEqual([200, 'other.example.com']);
    expect((await handleForward(ask('https://api.example.com/away'), env, chain)).headers.get('x-forward-error')).toBe('redirect');
    hops = 0;
    expect((await handleForward(ask('https://api.example.com/loop'), env, chain)).headers.get('x-forward-error')).toBe('redirect');
    expect(hops).toBe(forwardMaxRedirects + 1);
  });

  it('回复超过上限（声明的长度或边读边数）不带回；上游连不上与超时各有原因', async () => {
    const declared = await handleForward(ask('https://api.example.com/x'), env, recorder(() => new Response('x', { headers: { 'content-length': String(forwardMaxBytes + 1) } })).fetcher);
    expect([declared.status, declared.headers.get('x-forward-error')]).toEqual([502, 'too_large']);
    const streamed = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(forwardMaxBytes));
        controller.enqueue(new Uint8Array(1));
        controller.close();
      },
    });
    expect((await handleForward(ask('https://api.example.com/x'), env, recorder(() => new Response(streamed)).fetcher)).headers.get('x-forward-error')).toBe('too_large');
    const exact = await handleForward(ask('https://api.example.com/x'), env, recorder(() => new Response(new Uint8Array(forwardMaxBytes))).fetcher);
    expect((await exact.arrayBuffer()).byteLength).toBe(forwardMaxBytes);
    const down: typeof fetch = async () => {
      throw new TypeError('connection refused');
    };
    expect((await handleForward(ask('https://api.example.com/x'), env, down)).headers.get('x-forward-error')).toBe('unreachable');
    const hanging: typeof fetch = (_input, init) => new Promise((_resolve, reject) => init?.signal?.addEventListener('abort', () => reject(init.signal?.reason)));
    const slow = await handleForward(ask('https://api.example.com/x'), env, hanging, 20);
    expect([slow.status, slow.headers.get('x-forward-error')]).toEqual([504, 'timeout']);
  });

  it('按 IP 限流：超了不转；入口就是 handleForward', async () => {
    const keys: string[] = [];
    const limited = { ...env, LIMITER: { limit: async ({ key }: { key: string }) => (keys.push(key), { success: false }) } };
    const { seen, fetcher } = recorder(() => new Response('ok'));
    const reply = await handleForward(ask('https://api.example.com/x', { headers: { 'cf-connecting-ip': '203.0.113.9' } }), limited, fetcher);
    expect([reply.status, reply.headers.get('x-forward-error'), keys, seen.length]).toEqual([429, 'rate_limited', ['203.0.113.9'], 0]);
    expect((await worker.fetch(new Request('https://edge.example.net/'), env)).headers.get('x-forward-error')).toBe('not_found');
  });
});
