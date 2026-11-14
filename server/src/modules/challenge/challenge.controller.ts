import { Body, Controller, Get, HttpCode, Param, Post, Query, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { ChallengeService } from 'src/modules/challenge/challenge.service';
import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import * as dtos from 'src/modules/challenge/challenge.dto';

// 挑战：用应用账号的设备密钥签名。看开放的挑战、开局、看局面、逐关交答案、提前结束。
@ApiTags('challenge')
@Controller('v1')
@UseGuards(DeviceAuthGuard)
export class ChallengeController {
  constructor(private readonly challenges: ChallengeService) {}

  @Get('challenges')
  list(@CurrentDevice() deviceId: string, @Query() query: dtos.ChallengeListQueryDto): Promise<dtos.ChallengeListDto> {
    return this.challenges.list(deviceId, query.games.split(','));
  }

  @Post('challenges/:challengeId/runs')
  @HttpCode(200)
  start(@CurrentDevice() deviceId: string, @Param() param: dtos.ChallengeParamDto, @Body() body: dtos.ChallengeStartBodyDto): Promise<dtos.ChallengeRunDto> {
    return this.challenges.start(deviceId, param.challengeId, body.games);
  }

  @Get('challenge-runs/:runId')
  view(@CurrentDevice() deviceId: string, @Param() param: dtos.ChallengeRunParamDto): Promise<dtos.ChallengeRunDto> {
    return this.challenges.view(deviceId, param.runId);
  }

  @Post('challenge-runs/:runId/levels/:levelId/answers')
  @HttpCode(200)
  answer(@CurrentDevice() deviceId: string, @Param() param: dtos.ChallengeLevelParamDto, @Body() body: dtos.ChallengeAnswerBodyDto): Promise<dtos.ChallengeAnswerDto> {
    return this.challenges.answer(deviceId, param.runId, param.levelId, body.attempt, body.answer);
  }

  @Post('challenge-runs/:runId/end')
  @HttpCode(200)
  end(@CurrentDevice() deviceId: string, @Param() param: dtos.ChallengeRunParamDto): Promise<dtos.ChallengeRunDto> {
    return this.challenges.end(deviceId, param.runId);
  }
}
