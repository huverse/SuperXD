import 'reflect-metadata';
import { HttpStatus, ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { NestExpressApplication } from '@nestjs/platform-express';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import type { NextFunction, Request, Response } from 'express';

import { AppModule } from 'src/app.module';
import { env } from 'src/config/env';
import { applyHttpTimeouts } from 'src/common/http_server';
import { ErrorMonitor, RelayLogger } from 'src/common/error_monitor';
import { RelayErrorFilter } from 'src/common/relay_error.filter';
import { RelayCode } from 'src/common/relay_error';
import { chaoxingRequestMaxBytes } from 'src/common/relay_limits';
import { ConfigRevision } from 'src/modules/app_release/config_revision';
import { diagnosticBodyLimit } from 'src/modules/diagnostic/diagnostic_body_limit';

// 组装 HTTP 应用，测试与启动共用；rawBody 供请求签名核对请求体哈希。
export const createRelayApp = async () => {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, { rawBody: true, abortOnError: false });
  applyHttpTimeouts(app.getHttpServer());
  // 不在回复头里报框架（x-powered-by: Express），少给扫描器一条线索。
  app.disable('x-powered-by');
  // 之后的 error 级日志先计数再输出（错误计数与告警，人工决策见 src/common/error_monitor.ts）；启动中的日志照旧由默认出口输出。
  const monitor = app.get(ErrorMonitor);
  app.useLogger(new RelayLogger(monitor));
  // 代签接口不签名、包只有 2KB：在通用的请求体解析之前按声明长度挡掉超过 8KB 的，不让它先吃掉 400KB 的解析成本
  // （校验不过的请求进不到限流计数）。没声明长度的分块上传一律拒，客户端总会带长度。
  app.use('/v1/chaoxing', (request: Request, response: Response, next: NextFunction) => {
    const declared = request.headers['content-length'];
    const chunked = declared === undefined && request.headers['transfer-encoding'] !== undefined;
    if (chunked || Number(declared ?? 0) > chaoxingRequestMaxBytes) {
      response.status(HttpStatus.PAYLOAD_TOO_LARGE).json({ code: RelayCode.envelopeTooLarge, message: '请求体过大' });
      return;
    }
    next();
  });
  // 诊断包是二进制请求体、最大 24MB：同样在通用解析之前按声明长度与类型挡掉不合格的，请求体留给控制器按流写盘。
  app.use('/v1/diagnostics', diagnosticBodyLimit);
  // 每条回复带公共灰度配置的版本号，手机看到变了就马上重新取（人工决策见 src/modules/app_release/config_revision.ts）；错误回复也带。
  const revision = app.get(ConfigRevision);
  app.use((_request: Request, response: Response, next: NextFunction) => {
    if (revision.value !== null) response.setHeader('x-sxd-config', revision.value);
    next();
  });
  // 请求体上限：密文 256KB 经 base64url 膨胀约 342KB，外加字段，留到 400KB。
  app.useBodyParser('json', { limit: '400kb' });
  app.set('trust proxy', env().trustProxy);
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
  app.useGlobalFilters(new RelayErrorFilter(monitor));
  app.enableShutdownHooks();
  if (env().swagger) {
    SwaggerModule.setup('v1/docs', app, SwaggerModule.createDocument(app, new DocumentBuilder().setTitle('SuperXD Relay').setVersion('1').build()));
  }
  return app;
};
