import { Controller, Get, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { FlagTargetService } from 'src/modules/flag_target/flag_target.service';
import * as dtos from 'src/modules/flag_target/flag_target.dto';

// 灰度点名：用应用账号的设备密钥签名，问这个账号被点名了哪些开关。
@ApiTags('flags')
@Controller('v1/flags')
@UseGuards(DeviceAuthGuard)
export class FlagTargetController {
  constructor(private readonly targets: FlagTargetService) {}

  @Get('mine')
  mine(@CurrentDevice() deviceId: string): Promise<dtos.FlagTargetsDto> {
    return this.targets.mine(deviceId);
  }
}
