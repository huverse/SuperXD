import { Body, Controller, Delete, Get, HttpCode, Ip, Param, Post, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { AccountService } from 'src/modules/account/account.service';
import { CurrentDevice, DeviceAuthGuard, SelfSigned } from 'src/modules/device/device_auth.guard';
import * as dtos from 'src/modules/account/account.dto';

// 应用账号（人工决策见 AccountService）：用户名加密码，一把设备密钥登录一个账号，全部请求带设备签名；
// 退出账号就是删掉这把设备密钥（DELETE /v1/devices，pairing 连带删登记）。
@ApiTags('account')
@Controller('v1/account')
@UseGuards(DeviceAuthGuard)
export class AccountController {
  constructor(private readonly accounts: AccountService) {}

  @Post('register')
  @HttpCode(200)
  @SelfSigned()
  register(@CurrentDevice() deviceId: string, @Body() body: dtos.AccountCredentialBodyDto, @Ip() ip: string): Promise<dtos.AccountSignedInDto> {
    return this.accounts.register(deviceId, ip, body);
  }

  @Post('login')
  @HttpCode(200)
  @SelfSigned()
  login(@CurrentDevice() deviceId: string, @Body() body: dtos.AccountCredentialBodyDto, @Ip() ip: string): Promise<dtos.AccountSignedInDto> {
    return this.accounts.login(deviceId, ip, body);
  }

  // 忘了密码：凭恢复码设新密码并换一个新恢复码。
  @Post('recover')
  @HttpCode(200)
  @SelfSigned()
  recover(@CurrentDevice() deviceId: string, @Body() body: dtos.AccountCredentialBodyDto, @Ip() ip: string): Promise<dtos.AccountSignedInDto> {
    return this.accounts.recover(deviceId, ip, body);
  }

  // 登录着的设备改密码、换恢复码。
  @Post('password')
  @HttpCode(204)
  changePassword(@CurrentDevice() deviceId: string, @Body() body: dtos.AccountSecretBodyDto) {
    return this.accounts.changeSecret(deviceId, 'password', body);
  }

  @Post('recovery-code')
  @HttpCode(204)
  changeRecoveryCode(@CurrentDevice() deviceId: string, @Body() body: dtos.AccountSecretBodyDto) {
    return this.accounts.changeSecret(deviceId, 'recoveryCode', body);
  }

  // 扫码登录：新设备出示（自签名）、已登录的设备批准、新设备轮询。
  @Post('joins')
  @HttpCode(200)
  @SelfSigned()
  startJoin(@CurrentDevice() deviceId: string, @Body() body: dtos.AccountDeviceKeysDto, @Ip() ip: string): Promise<dtos.AccountJoinDto> {
    return this.accounts.startJoin(deviceId, ip, body);
  }

  @Post('joins/:ticketId/approve')
  @HttpCode(204)
  approveJoin(@CurrentDevice() deviceId: string, @Param() param: dtos.AccountJoinParamDto, @Body() body: dtos.AccountJoinApproveBodyDto) {
    return this.accounts.approveJoin(deviceId, param.ticketId, body.code);
  }

  @Get('joins/:ticketId')
  joinState(@CurrentDevice() deviceId: string, @Param() param: dtos.AccountJoinParamDto): Promise<dtos.AccountJoinStateDto> {
    return this.accounts.joinState(deviceId, param.ticketId);
  }

  @Get()
  summary(@CurrentDevice() deviceId: string): Promise<dtos.AccountSummaryDto> {
    return this.accounts.summary(deviceId);
  }

  // 注销账号：全部设备密钥的登记、账号下的数据与账号本身；客户端随后再删这把设备密钥。
  @Delete()
  @HttpCode(204)
  remove(@CurrentDevice() deviceId: string) {
    return this.accounts.remove(deviceId);
  }
}
