import { Controller, Get, HttpStatus, Res } from '@nestjs/common';
import { ApiProperty, ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';

import { env } from 'src/config/env';
import { HealthService } from 'src/modules/health/health.service';

export class HealthDto {
  @ApiProperty({ description: '协议版本' }) protocol: number;
  @ApiProperty({ description: '服务器时间，毫秒；客户端据此校正时钟偏差' }) serverTime: number;
  @ApiProperty({ description: '构建版本：流水线构建镜像时注入的提交号，本地开发为 dev；客户端不读，供部署核对与外部探活' }) version: string;
}

export class ReadyDto {
  @ApiProperty({ description: '能否服务：MySQL 与 Redis 都在限时内回应；不能时状态码 503' }) ready: boolean;
  @ApiProperty({ description: 'MySQL：ok、timeout（限时内没回应）或 down（出错）' }) mysql: string;
  @ApiProperty({ description: 'Redis：同上' }) redis: string;
  @ApiProperty({ description: '最近一个折叠窗口里告警过的错误签名个数（只有个数，明细在服务器日志的 [Alert] 行）；外部探活读到非零就报' }) alerts: number;
  @ApiProperty({ description: '构建版本，同 /v1/health' }) version: string;
}

// 免签名：客户端探活与校时，部署后核对线上是哪个提交。
@ApiTags('health')
@Controller('v1/health')
export class HealthController {
  constructor(private readonly healthService: HealthService) {}

  @Get()
  health(): HealthDto {
    return { protocol: 1, serverTime: Date.now(), version: env().buildVersion };
  }

  // 就绪探测：容器健康检查与 GitHub 上的外部探活用它（人工决策见 src/common/error_monitor.ts）；客户端不用。
  @Get('ready')
  async ready(@Res({ passthrough: true }) response: Response): Promise<ReadyDto> {
    const readiness = await this.healthService.ready();
    if (!readiness.ready) response.status(HttpStatus.SERVICE_UNAVAILABLE);
    return readiness;
  }
}
