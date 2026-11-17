import { ArgumentsHost, Catch, ExceptionFilter, HttpException, HttpStatus, Logger } from '@nestjs/common';
import type { Response } from 'express';

import { ErrorMonitor } from 'src/common/error_monitor';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { shedAlertPerMinute } from 'src/common/relay_limits';

// 统一错误响应 {code, message, ...extra}；未预期异常打印完整堆栈后只回 INTERNAL，不泄露内部信息。
// 主动卸载负载的 503（RelayError）不记日志，只计数，一分钟多了才告警（见 src/common/error_monitor.ts）。
@Catch()
export class RelayErrorFilter implements ExceptionFilter {
  private readonly logger = new Logger('RelayError');

  constructor(private readonly monitor: ErrorMonitor) {}

  catch(error: unknown, host: ArgumentsHost) {
    const response = host.switchToHttp().getResponse<Response>();
    if (error instanceof RelayError) {
      if (error.status >= HttpStatus.INTERNAL_SERVER_ERROR) this.monitor.recordShed(error.code, error.status, shedAlertPerMinute);
      response.status(error.status).json({ code: error.code, message: error.message, ...error.extra });
      return;
    }
    if (error instanceof HttpException && error.getStatus() < 500) {
      const status = error.getStatus();
      const code = status === HttpStatus.PAYLOAD_TOO_LARGE ? RelayCode.envelopeTooLarge : RelayCode.invalidRequest;
      response.status(status).json({ code, message: error.message });
      return;
    }
    // body-parser 超限抛的是带 status 的普通错误。
    if (error instanceof Error && (error as Error & { status?: number }).status === HttpStatus.PAYLOAD_TOO_LARGE) {
      response.status(HttpStatus.PAYLOAD_TOO_LARGE).json({ code: RelayCode.envelopeTooLarge, message: '请求体过大' });
      return;
    }
    console.error(error);
    this.logger.error(`[RelayError] action=unhandled errorType=${error instanceof Error ? error.constructor.name : typeof error}`);
    response.status(HttpStatus.INTERNAL_SERVER_ERROR).json({ code: RelayCode.internal, message: '服务暂时不可用' });
  }
}
