import 'reflect-metadata';
import { ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { NestExpressApplication } from '@nestjs/platform-express';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';

import { AppModule } from 'src/app.module';
import { env } from 'src/config/env';
import { RelayErrorFilter } from 'src/common/relay_error.filter';

// 组装 HTTP 应用，测试与启动共用；rawBody 供请求签名核对请求体哈希。
export const createRelayApp = async () => {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, { rawBody: true, abortOnError: false });
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
