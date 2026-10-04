import { Injectable } from '@nestjs/common';
import { DataSource } from 'typeorm';

import { DeviceRepository } from 'src/modules/device/device.repository';
import { DeviceService } from 'src/modules/device/device.service';
import { FriendshipRepository } from 'src/modules/friend/friendship.repository';
import { MessageRepository } from 'src/modules/message/message.repository';

// 删除设备连同其好友关系与待收消息，同一事务完成；用户关闭私信与长期不活跃清理共用。
@Injectable()
export class DeviceRemovalService {
  constructor(
    private readonly dataSource: DataSource,
    private readonly devices: DeviceRepository,
    private readonly deviceService: DeviceService,
    private readonly friendships: FriendshipRepository,
    private readonly messages: MessageRepository,
  ) {}

  async remove(deviceIds: string[]) {
    if (deviceIds.length === 0) return;
    await this.dataSource.transaction(async (manager) => {
      await this.friendships.removeAllOf(deviceIds, manager);
      await this.messages.removeMailboxes(deviceIds, manager);
      await this.devices.remove(deviceIds, manager);
    });
    this.deviceService.forget(deviceIds);
  }
}
