import { Module } from '@nestjs/common';

import { DeviceModule } from 'src/modules/device/device.module';
import { InviteController } from 'src/modules/invite/invite.controller';
import { InviteService } from 'src/modules/invite/invite.service';
import { InviteStore, RedisInviteStore } from 'src/modules/invite/invite.store';

@Module({
  imports: [DeviceModule],
  controllers: [InviteController],
  providers: [{ provide: InviteStore, useClass: RedisInviteStore }, InviteService],
  exports: [InviteService],
})
export class InviteModule {}
