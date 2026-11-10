import { HttpStatus } from '@nestjs/common';
import type { NextFunction, Request, Response } from 'express';

import { RelayCode } from 'src/common/relay_error';
import { diagnosticUploadMaxBytes } from 'src/common/relay_limits';

// 诊断包接口不签名、包最大 24MB：由 relay_app.ts 挂在通用请求体解析之前，按声明长度挡掉超限的与没声明长度的分块上传（客户端总会带长度），
// 也只收二进制请求体，别的类型不让通用 JSON 解析器先去解析（校验不过的请求进不到限流计数）。请求体留给控制器按流写盘。
export const diagnosticBodyLimit = (request: Request, response: Response, next: NextFunction) => {
  const declared = request.headers['content-length'];
  const chunked = declared === undefined && request.headers['transfer-encoding'] !== undefined;
  if (chunked || Number(declared ?? 0) > diagnosticUploadMaxBytes) {
    response.status(HttpStatus.PAYLOAD_TOO_LARGE).json({ code: RelayCode.envelopeTooLarge, message: '诊断包过大' });
    return;
  }
  if (request.method === 'POST' && request.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/octet-stream') {
    response.status(HttpStatus.UNSUPPORTED_MEDIA_TYPE).json({ code: RelayCode.invalidRequest, message: '诊断包须为二进制请求体' });
    return;
  }
  next();
};
