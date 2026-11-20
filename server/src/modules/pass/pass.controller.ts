import { Controller, Get, HttpCode, Ip, Param, Post, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { PassService } from 'src/modules/pass/pass.service';
import * as dtos from 'src/modules/pass/pass.dto';

// 积分时长券（规则见 pass.service.ts）：清单公开，自己的券与购买用应用账号的设备密钥签名。
@ApiTags('passes')
@Controller()
export class PassController {
  constructor(private readonly passes: PassService) {}

  @Get('v1/app/passes')
  offers(@Ip() ip: string): Promise<dtos.PassOffersDto> {
    return this.passes.offers(ip);
  }

  @Get('v1/passes')
  @UseGuards(DeviceAuthGuard)
  state(@CurrentDevice() deviceId: string): Promise<dtos.PassStateDto> {
    return this.passes.state(deviceId);
  }

  @Post('v1/passes/:id/buy')
  @HttpCode(200)
  @UseGuards(DeviceAuthGuard)
  buy(@CurrentDevice() deviceId: string, @Param() params: dtos.PassParamDto): Promise<dtos.PassStateDto> {
    return this.passes.buy(deviceId, params.id);
  }
}
