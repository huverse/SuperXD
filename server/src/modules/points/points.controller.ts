import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { PointsService } from 'src/modules/points/points.service';
import * as dtos from 'src/modules/points/points.dto';

// 积分：用应用账号的设备密钥签名，看这个账号的余额与流水。
@ApiTags('points')
@Controller('v1/points')
@UseGuards(DeviceAuthGuard)
export class PointsController {
  constructor(private readonly points: PointsService) {}

  @Get()
  summary(@CurrentDevice() deviceId: string): Promise<dtos.PointsSummaryDto> {
    return this.points.summary(deviceId);
  }

  @Get('entries')
  entries(@CurrentDevice() deviceId: string, @Query() query: dtos.PointsEntriesQueryDto): Promise<dtos.PointsEntriesDto> {
    return this.points.entries(deviceId, query.before);
  }
}
