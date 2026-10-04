import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { DataSource } from 'typeorm';

import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { friendLimit, redeemPerMinute } from 'src/common/relay_limits';
import { DeviceRepository } from 'src/modules/device/device.repository';
import { FriendshipRepository } from 'src/modules/friend/friendship.repository';
import { InviteService } from 'src/modules/invite/invite.service';
import { MessageService } from 'src/modules/message/message.service';

// 扫码加好友：跨邀请、好友、信箱三个领域的编排，归这一层调度，下层互不感知。
@Injectable()
export class PairingService {
  private readonly logger = new Logger('Pairing');

  constructor(
    private readonly dataSource: DataSource,
    private readonly invites: InviteService,
    private readonly devices: DeviceRepository,
    private readonly friendships: FriendshipRepository,
    private readonly messages: MessageService,
    private readonly limiter: RateLimiter,
  ) {}

  // [人工决策-2026-10-04 16:44:36] 扫码即成为好友：出示二维码视为同意，邀请 5 分钟有效、期内可被多人扫，新建即作废旧的；不做好友申请确认。
  // 关系与给邀请人的问候在同一事务里写入：邀请人一定能收到扫码方的公钥与昵称，不会出现服务端有关系、本机没好友。
  async redeem(redeemerDeviceId: string, inviteId: string, proof: string, helloClientId: string, helloEnvelope: string) {
    const retryAfter = await this.limiter.hit('redeem', redeemerDeviceId, redeemPerMinute, 60);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '操作过于频繁', { retryAfter });
    const ownerDeviceId = await this.invites.verify(inviteId, redeemerDeviceId, proof);
    const hello = this.messages.decodeEnvelope(helloEnvelope);
    const since = await this.dataSource.transaction(async (manager) => {
      // 按设备号顺序锁住双方设备行，串行化同一设备的并发加好友，好友上限才准确，且不会互相死锁。
      const pair = [ownerDeviceId, redeemerDeviceId].sort();
      if ((await this.devices.lock(pair, manager)).length !== 2) throw new RelayError(RelayCode.peerNotFound, HttpStatus.NOT_FOUND, '对方设备不存在');
      if (!(await this.friendships.isFriend(redeemerDeviceId, ownerDeviceId))) {
        for (const deviceId of pair) {
          if ((await this.friendships.count(deviceId, manager)) >= friendLimit) throw new RelayError(RelayCode.friendLimit, HttpStatus.CONFLICT, '好友数量已达上限');
        }
        await this.friendships.connect(ownerDeviceId, redeemerDeviceId, manager);
      }
      const stored = await this.messages.deliver(ownerDeviceId, redeemerDeviceId, helloClientId, hello, manager);
      return stored.createTime.getTime();
    });
    this.logger.log(`[Pairing] action=redeem ownerDeviceId=${ownerDeviceId} redeemerDeviceId=${redeemerDeviceId}`);
    return { deviceId: ownerDeviceId, since };
  }
}
