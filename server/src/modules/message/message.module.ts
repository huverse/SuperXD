import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { DeviceModule } from 'src/modules/device/device.module';
import { FriendModule } from 'src/modules/friend/friend.module';
import { MessageController } from 'src/modules/message/message.controller';
import { MessageEntity } from 'src/modules/message/message.entity';
import { MessageRepository, TypeormMessageRepository } from 'src/modules/message/message.repository';
import { MessageService } from 'src/modules/message/message.service';
import { MailboxNotifier } from 'src/modules/message/mailbox_notifier';

@Module({
  imports: [TypeOrmModule.forFeature([MessageEntity]), DeviceModule, FriendModule],
  controllers: [MessageController],
  providers: [{ provide: MessageRepository, useClass: TypeormMessageRepository }, MessageService, MailboxNotifier],
  exports: [MessageRepository, MessageService, MailboxNotifier],
})
export class MessageModule {}
