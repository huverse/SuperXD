import { Body, Controller, HttpCode, Post, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { PairingService } from 'src/modules/pairing/pairing.service';
import * as dtos from 'src/modules/friend/friend.dto';

@ApiTags('friend')
@Controller('v1/friends')
@UseGuards(DeviceAuthGuard)
export class PairingController {
  constructor(private readonly pairing: PairingService) {}

  @Post('redeem')
  @HttpCode(200)
  redeem(@CurrentDevice() deviceId: string, @Body() body: dtos.RedeemInviteDto): Promise<dtos.RedeemInviteResultDto> {
    return this.pairing.redeem(deviceId, body.inviteId, body.proof, body.hello.clientId, body.hello.envelope);
  }
}
