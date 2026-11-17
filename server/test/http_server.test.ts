import { createServer } from 'node:http';

import { applyHttpTimeouts } from 'src/common/http_server';
import { httpHeadersTimeoutMs, httpKeepAliveTimeoutMs, httpRequestTimeoutMs } from 'src/common/relay_limits';

// HTTP 服务端超时（取值与原因见 relay_limits.ts）：不连库，只看设到 Node 服务上的值与它们之间的关系。
describe('HTTP 服务端超时', () => {
  it('三个超时都显式设上，且彼此关系合理', () => {
    const server = createServer();
    applyHttpTimeouts(server);
    expect(server.requestTimeout).toBe(httpRequestTimeoutMs);
    expect(server.headersTimeout).toBe(httpHeadersTimeoutMs);
    expect(server.keepAliveTimeout).toBe(httpKeepAliveTimeoutMs);
    // 收完整个请求的时限要容得下客户端诊断包上传的 5 分钟，请求头时限不长过它。
    expect(httpRequestTimeoutMs).toBeGreaterThan(5 * 60_000);
    expect(httpHeadersTimeoutMs).toBeLessThanOrEqual(httpRequestTimeoutMs);
    // 保活要长过客户端关空闲连接（Dart 15 秒）与前置代理的上游保活（Nginx 60 秒），请求头时限再长一点。
    expect(httpKeepAliveTimeoutMs).toBeGreaterThan(60_000);
    expect(httpHeadersTimeoutMs).toBeGreaterThan(httpKeepAliveTimeoutMs);
  });
});
