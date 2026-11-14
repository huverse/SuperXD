import { Controller, Get, HttpCode, Param, Post, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { UnlockService } from 'src/modules/unlock/unlock.service';
import * as dtos from 'src/modules/unlock/unlock.dto';

// 解锁：用应用账号的设备密钥签名，看这个账号能用哪些、花积分买一项。
@ApiTags('unlocks')
@Controller('v1/unlocks')
@UseGuards(DeviceAuthGuard)
export class UnlockController {
  constructor(private readonly unlocks: UnlockService) {}

  @Get()
  state(@CurrentDevice() deviceId: string): Promise<dtos.UnlockStateDto> {
    return this.unlocks.state(deviceId);
  }

  @Post(':id/buy')
  @HttpCode(200)
  buy(@CurrentDevice() deviceId: string, @Param() params: dtos.UnlockParamDto): Promise<dtos.UnlockStateDto> {
    return this.unlocks.buy(deviceId, params.id);
  }
}
