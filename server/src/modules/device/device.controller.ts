import { Body, Controller, HttpCode, Ip, Post, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard, SelfSigned } from 'src/modules/device/device_auth.guard';
import { DeviceService } from 'src/modules/device/device.service';
import * as dtos from 'src/modules/device/device.dto';

@ApiTags('device')
@Controller('v1/devices')
@UseGuards(DeviceAuthGuard)
export class DeviceController {
  constructor(private readonly devices: DeviceService) {}

  @Post()
  @HttpCode(200)
  @SelfSigned()
  async register(@CurrentDevice() deviceId: string, @Body() body: dtos.RegisterDeviceDto, @Ip() ip: string): Promise<dtos.RegisterDeviceResultDto> {
    await this.devices.register(deviceId, body.signPublicKey, body.boxPublicKey, ip);
    return { deviceId, serverTime: Date.now() };
  }
}
