import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccountModule } from 'src/modules/account/account.module';
import { DeviceModule } from 'src/modules/device/device.module';
import { FriendModule } from 'src/modules/friend/friend.module';
import { InviteModule } from 'src/modules/invite/invite.module';
import { MessageModule } from 'src/modules/message/message.module';
import { AccountSocialEntity } from 'src/modules/pairing/account_social.entity';
import { AccountSocialRepository, TypeormAccountSocialRepository } from 'src/modules/pairing/account_social.repository';
import { DeviceRemovalController } from 'src/modules/pairing/device_removal.controller';
import { DeviceRemovalService } from 'src/modules/pairing/device_removal.service';
import { PairingController } from 'src/modules/pairing/pairing.controller';
import { PairingService } from 'src/modules/pairing/pairing.service';
import { RetentionTask } from 'src/modules/pairing/retention.task';
import { SocialBindingController } from 'src/modules/pairing/social_binding.controller';
import { SocialBindingService } from 'src/modules/pairing/social_binding.service';

// 跨领域编排层：扫码加好友、删除设备、私信挂到应用账号（含换设备接管）与数据保留清理，依赖设备、邀请、好友、信箱与应用账号，反之不依赖。
@Module({
  imports: [TypeOrmModule.forFeature([AccountSocialEntity]), DeviceModule, InviteModule, FriendModule, MessageModule, AccountModule],
  controllers: [PairingController, DeviceRemovalController, SocialBindingController],
  providers: [{ provide: AccountSocialRepository, useClass: TypeormAccountSocialRepository }, PairingService, DeviceRemovalService, RetentionTask, SocialBindingService],
})
export class PairingModule {}
