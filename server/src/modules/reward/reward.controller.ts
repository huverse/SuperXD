import { Body, Controller, HttpCode, Ip, Param, Post } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { RewardService } from 'src/modules/reward/reward.service';
import * as dtos from 'src/modules/reward/reward.dto';

// 节日抽奖：免签名（不要求开启私信），凭客户端本机生成的随机参与号幂等。
@ApiTags('reward')
@Controller('v1/rewards')
export class RewardController {
  constructor(private readonly rewards: RewardService) {}

  @Post(':campaign/draw')
  @HttpCode(200)
  draw(@Param() param: dtos.RewardDrawParamDto, @Body() body: dtos.RewardDrawBodyDto, @Ip() ip: string): Promise<dtos.RewardDrawDto> {
    return this.rewards.draw(ip, param.campaign, body);
  }
}
