// 中转向外发请求的统一封装（现在只有电影院片名目录的抓取用）：每次都有显式超时与响应字节上限，超了就中断，不自动重试（要重试由调用方按自己的规矩决定）。
export class OutboundHttpError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message);
  }
}

export const fetchText = async (url: string, options: { timeoutMs: number; maxBytes: number; headers?: Record<string, string> }): Promise<string> => {
  const response = await fetch(url, { headers: options.headers, redirect: 'follow', signal: AbortSignal.timeout(options.timeoutMs) });
  if (!response.ok) throw new OutboundHttpError(`HTTP ${response.status}`, response.status);
  const declared = Number(response.headers.get('content-length') ?? '0');
  if (declared > options.maxBytes) throw new OutboundHttpError('回复太大');
  const reader = response.body?.getReader();
  if (reader === undefined) return '';
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > options.maxBytes) {
      await reader.cancel();
      throw new OutboundHttpError('回复太大');
    }
    chunks.push(value);
  }
  return new TextDecoder('utf-8', { fatal: false }).decode(Buffer.concat(chunks));
};
