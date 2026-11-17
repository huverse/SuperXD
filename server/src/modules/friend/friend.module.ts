import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { RelaySigner } from 'src/common/crypto/relay_signer';
import { DeviceModule } from 'src/modules/device/device.module';
import { FriendController } from 'src/modules/friend/friend.controller';
import { FriendKeySigner } from 'src/modules/friend/friend_key_signer';
import { FriendService } from 'src/modules/friend/friend.service';
import { FriendshipEntity } from 'src/modules/friend/friendship.entity';
import { FriendshipRepository, TypeormFriendshipRepository } from 'src/modules/friend/friendship.repository';

@Module({
  imports: [TypeOrmModule.forFeature([FriendshipEntity]), DeviceModule],
  controllers: [FriendController],
  providers: [{ provide: FriendshipRepository, useClass: TypeormFriendshipRepository }, RelaySigner, FriendKeySigner, FriendService],
  exports: [FriendshipRepository, FriendService],
})
export class FriendModule {}
