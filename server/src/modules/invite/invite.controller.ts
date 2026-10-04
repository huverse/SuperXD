import { Body, Controller, Delete, HttpCode, Param, Post, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { InviteService } from 'src/modules/invite/invite.service';
import * as dtos from 'src/modules/invite/invite.dto';

@ApiTags('invite')
@Controller('v1/invites')
@UseGuards(DeviceAuthGuard)
export class InviteController {
  constructor(private readonly invites: InviteService) {}

  @Post()
  @HttpCode(200)
  async create(@CurrentDevice() deviceId: string, @Body() body: dtos.CreateInviteDto): Promise<dtos.CreateInviteResultDto> {
    return { inviteId: body.inviteId, expiresAt: await this.invites.create(deviceId, body.inviteId, body.publicKey) };
  }

  @Delete(':inviteId')
  @HttpCode(204)
  async revoke(@CurrentDevice() deviceId: string, @Param('inviteId') inviteId: string) {
    await this.invites.revoke(deviceId, inviteId);
  }
}
