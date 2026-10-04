import { Controller, Delete, Get, HttpCode, Param, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { FriendService } from 'src/modules/friend/friend.service';
import * as dtos from 'src/modules/friend/friend.dto';

@ApiTags('friend')
@Controller('v1/friends')
@UseGuards(DeviceAuthGuard)
export class FriendController {
  constructor(private readonly friends: FriendService) {}

  @Get()
  async list(@CurrentDevice() deviceId: string): Promise<dtos.FriendListDto> {
    return { friends: await this.friends.list(deviceId) };
  }

  @Delete(':peerDeviceId')
  @HttpCode(204)
  async remove(@CurrentDevice() deviceId: string, @Param('peerDeviceId') peerDeviceId: string) {
    await this.friends.remove(deviceId, peerDeviceId);
  }
}
