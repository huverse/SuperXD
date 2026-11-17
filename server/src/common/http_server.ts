import type { Server } from 'node:http';

import { httpHeadersTimeoutMs, httpKeepAliveTimeoutMs, httpRequestTimeoutMs } from 'src/common/relay_limits';

// 显式设 HTTP 服务端的三个超时（取值与原因见 relay_limits.ts），不靠 Node 的默认值：一个慢客户端占着连接不放、拖垮连接数。
export const applyHttpTimeouts = (server: Server) => {
  server.requestTimeout = httpRequestTimeoutMs;
  server.headersTimeout = httpHeadersTimeoutMs;
  server.keepAliveTimeout = httpKeepAliveTimeoutMs;
};
