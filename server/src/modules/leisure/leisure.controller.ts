import { Controller, Delete, HttpCode, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { LeisureService } from 'src/modules/leisure/leisure.service';

// 游乐场与积分：用应用账号的设备密钥签名，删掉这个账号的积分、挑战成绩与解锁记录。
@ApiTags('leisure')
@Controller('v1/leisure')
@UseGuards(DeviceAuthGuard)
export class LeisureController {
  constructor(private readonly leisure: LeisureService) {}

  @Delete()
  @HttpCode(204)
  remove(@CurrentDevice() deviceId: string) {
    return this.leisure.remove(deviceId);
  }
}
