import { Module } from '@nestjs/common';

import { ChaoxingPackModule } from 'src/modules/chaoxing/chaoxing_pack.module';
import { DeviceModule } from 'src/modules/device/device.module';
import { FriendModule } from 'src/modules/friend/friend.module';
import { InviteModule } from 'src/modules/invite/invite.module';
import { MessageModule } from 'src/modules/message/message.module';
import { DeviceRemovalController } from 'src/modules/pairing/device_removal.controller';
import { DeviceRemovalService } from 'src/modules/pairing/device_removal.service';
import { PairingController } from 'src/modules/pairing/pairing.controller';
import { PairingService } from 'src/modules/pairing/pairing.service';
import { RetentionTask } from 'src/modules/pairing/retention.task';

// 跨领域编排层：扫码加好友、删除设备与数据保留清理，依赖设备、邀请、好友、信箱，反之不依赖。
@Module({
  imports: [DeviceModule, InviteModule, FriendModule, MessageModule, ChaoxingPackModule],
  controllers: [PairingController, DeviceRemovalController],
  providers: [PairingService, DeviceRemovalService, RetentionTask],
})
export class PairingModule {}
