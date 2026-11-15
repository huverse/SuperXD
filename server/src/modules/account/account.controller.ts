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

  // 设备核对（人工决策见 AccountService.deviceSignIn）：自签名，手机自己登录教务后报学号。
  @Post('device-sign-in')
  @HttpCode(200)
  @SelfSigned()
  deviceSignIn(@CurrentDevice() deviceId: string, @Body() body: dtos.AccountDeviceBodyDto, @Ip() ip: string): Promise<dtos.AccountDeviceSignInDto> {
    return this.accounts.deviceSignIn(deviceId, ip, body);
  }

  // 扫码授权：新设备发起（自签名）、已登录的设备批准、新设备轮询。
  @Post('joins')
  @HttpCode(200)
  @SelfSigned()
  startJoin(@CurrentDevice() deviceId: string, @Body() body: dtos.AccountDeviceBodyDto): Promise<dtos.AccountJoinDto> {
    return this.accounts.startJoin(deviceId, body);
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

  // 找回：新设备提交（自签名）与查看自己的申请；账号的设备拒绝或批准。
  @Post('recoveries')
  @HttpCode(200)
  @SelfSigned()
  requestRecovery(@CurrentDevice() deviceId: string, @Body() body: dtos.AccountDeviceBodyDto, @Ip() ip: string): Promise<dtos.AccountRecoveryDto> {
    return this.accounts.requestRecovery(deviceId, ip, body);
  }

  @Get('recoveries/mine')
  recoveryState(@CurrentDevice() deviceId: string): Promise<dtos.AccountRecoveryDto> {
    return this.accounts.recoveryState(deviceId);
  }

  @Post('recoveries/:recoveryId/deny')
  @HttpCode(204)
  denyRecovery(@CurrentDevice() deviceId: string, @Param() param: dtos.AccountRecoveryParamDto) {
    return this.accounts.decideRecovery(deviceId, param.recoveryId, false);
  }

  @Post('recoveries/:recoveryId/approve')
  @HttpCode(204)
  approveRecovery(@CurrentDevice() deviceId: string, @Param() param: dtos.AccountRecoveryParamDto) {
    return this.accounts.decideRecovery(deviceId, param.recoveryId, true);
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
