import { Body, Controller, Delete, Get, HttpCode, Ip, Param, Post, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { AccountService } from 'src/modules/account/account.service';
import { CurrentDevice, DeviceAuthGuard, SelfSigned } from 'src/modules/device/device_auth.guard';
import * as dtos from 'src/modules/account/account.dto';

// 应用账号：一把设备密钥登录一个账号，全部请求带设备签名；退出账号就是删掉这把设备密钥（DELETE /v1/devices，pairing 连带删登记）。
@ApiTags('account')
@Controller('v1/account')
@UseGuards(DeviceAuthGuard)
export class AccountController {
  constructor(private readonly accounts: AccountService) {}

  @Post('sign-in/:provider')
  @HttpCode(200)
  @SelfSigned()
  signIn(@CurrentDevice() deviceId: string, @Param() param: dtos.AccountSignInParamDto, @Body() body: dtos.AccountSignInBodyDto, @Ip() ip: string): Promise<dtos.AccountSignInDto> {
    return this.accounts.signIn(deviceId, ip, param.provider, body);
  }

  @Get()
  summary(@CurrentDevice() deviceId: string): Promise<dtos.AccountSummaryDto> {
    return this.accounts.summary(deviceId);
  }

  // 注销账号：登录方式、全部设备密钥的登记与账号本身；客户端随后再删这把设备密钥。
  @Delete()
  @HttpCode(204)
  remove(@CurrentDevice() deviceId: string) {
    return this.accounts.remove(deviceId);
  }
}
