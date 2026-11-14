import { Body, Controller, HttpCode, Post, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { SocialBindingService } from 'src/modules/pairing/social_binding.service';
import * as dtos from 'src/modules/pairing/pairing.dto';

// 私信挂到应用账号：用应用账号的设备密钥签名（见 SocialBindingService）。
@ApiTags('account')
@Controller('v1/account/social')
@UseGuards(DeviceAuthGuard)
export class SocialBindingController {
  constructor(private readonly binding: SocialBindingService) {}

  @Post()
  @HttpCode(200)
  bind(@CurrentDevice() deviceId: string, @Body() body: dtos.BindSocialDto): Promise<dtos.BindSocialResultDto> {
    return this.binding.bind(deviceId, body);
  }
}
