import { Controller, Get } from '@nestjs/common';
import { ApiProperty, ApiTags } from '@nestjs/swagger';

export class HealthDto {
  @ApiProperty({ description: '协议版本' }) protocol: number;
  @ApiProperty({ description: '服务器时间，毫秒；客户端据此校正时钟偏差' }) serverTime: number;
}

// 免签名：客户端探活与校时。
@ApiTags('health')
@Controller('v1/health')
export class HealthController {
  @Get()
  health(): HealthDto {
    return { protocol: 1, serverTime: Date.now() };
  }
}
