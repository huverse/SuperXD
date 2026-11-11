import { Controller, Get } from '@nestjs/common';
import { ApiProperty, ApiTags } from '@nestjs/swagger';

import { env } from 'src/config/env';

export class HealthDto {
  @ApiProperty({ description: '协议版本' }) protocol: number;
  @ApiProperty({ description: '服务器时间，毫秒；客户端据此校正时钟偏差' }) serverTime: number;
  @ApiProperty({ description: '构建版本：流水线构建镜像时注入的提交号，本地开发为 dev；客户端不读，供部署核对与外部探活' }) version: string;
}

// 免签名：客户端探活与校时，部署后核对线上是哪个提交。
@ApiTags('health')
@Controller('v1/health')
export class HealthController {
  @Get()
  health(): HealthDto {
    return { protocol: 1, serverTime: Date.now(), version: env().buildVersion };
  }
}
