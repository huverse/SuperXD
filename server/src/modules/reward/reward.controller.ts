import { Body, Controller, Get, HttpCode, Ip, Param, Post, Query, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { RewardService } from 'src/modules/reward/reward.service';
import * as dtos from 'src/modules/reward/reward.dto';

// 节日抽奖：要求登录了应用账号的设备签名（人工决策见 reward_odds.ts），一个人一次活动只抽一次。
@ApiTags('reward')
@Controller('v1/rewards')
@UseGuards(DeviceAuthGuard)
export class RewardController {
  constructor(private readonly rewards: RewardService) {}

  @Get(':campaign')
  status(@CurrentDevice() deviceId: string, @Param() param: dtos.RewardDrawParamDto, @Query() query: dtos.RewardStatusQueryDto): Promise<dtos.RewardStatusDto> {
    return this.rewards.status(deviceId, param.campaign, query.levels !== '0');
  }

  @Post(':campaign/draw')
  @HttpCode(200)
  draw(@CurrentDevice() deviceId: string, @Param() param: dtos.RewardDrawParamDto, @Body() body: dtos.RewardDrawBodyDto, @Ip() ip: string): Promise<dtos.RewardDrawDto> {
    return this.rewards.draw(ip, deviceId, param.campaign, body);
  }
}
