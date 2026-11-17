import { Body, Controller, HttpCode, Ip, Post } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { AppHealthService } from 'src/modules/app_health/app_health.service';
import * as dtos from 'src/modules/app_health/app_health.dto';

// 健康回报与意见反馈：免签名、不带任何标识（规则见 app_health_rules.ts）。
@ApiTags('app')
@Controller('v1/app')
export class AppHealthController {
  constructor(private readonly health: AppHealthService) {}

  @Post('health')
  @HttpCode(204)
  report(@Ip() ip: string, @Body() body: dtos.HealthReportDto): Promise<void> {
    return this.health.report(ip, body);
  }

  @Post('feedback')
  @HttpCode(204)
  feedback(@Ip() ip: string, @Body() body: dtos.FeedbackDto): Promise<void> {
    return this.health.feedback(ip, body);
  }
}
