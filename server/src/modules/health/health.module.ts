import { Module } from '@nestjs/common';

import { HealthController } from 'src/modules/health/health.controller';
import { HealthService } from 'src/modules/health/health.service';

// 存活与就绪探测：连接池与 Redis 连接来自全局模块，错误计数来自全局的 ErrorMonitorModule。
@Module({ controllers: [HealthController], providers: [HealthService] })
export class HealthModule {}
