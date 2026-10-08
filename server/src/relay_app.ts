import 'reflect-metadata';
import { HttpStatus, ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { NestExpressApplication } from '@nestjs/platform-express';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import type { NextFunction, Request, Response } from 'express';

import { AppModule } from 'src/app.module';
import { env } from 'src/config/env';
import { RelayErrorFilter } from 'src/common/relay_error.filter';
import { RelayCode } from 'src/common/relay_error';
import { chaoxingRequestMaxBytes } from 'src/common/relay_limits';

// 组装 HTTP 应用，测试与启动共用；rawBody 供请求签名核对请求体哈希。
export const createRelayApp = async () => {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, { rawBody: true, abortOnError: false });
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
  // 请求体上限：密文 256KB 经 base64url 膨胀约 342KB，外加字段，留到 400KB。
  app.useBodyParser('json', { limit: '400kb' });
  app.set('trust proxy', env().trustProxy);
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
  app.useGlobalFilters(new RelayErrorFilter());
  app.enableShutdownHooks();
  if (env().swagger) {
    SwaggerModule.setup('v1/docs', app, SwaggerModule.createDocument(app, new DocumentBuilder().setTitle('SuperXD Relay').setVersion('1').build()));
  }
  return app;
};
