import { Injectable, Logger } from '@nestjs/common';

import { FriendshipRepository } from 'src/modules/friend/friendship.repository';

@Injectable()
export class FriendService {
  private readonly logger = new Logger('Friend');

  constructor(private readonly friendships: FriendshipRepository) {}

  async list(ownerDeviceId: string) {
    const rows = await this.friendships.list(ownerDeviceId);
    return rows.map((row) => ({ deviceId: row.peerDeviceId, since: row.createTime.getTime() }));
  }

  // 双向删除；对方之后发来的消息会被拒收（NOT_FRIEND），对方客户端据此标记“已解除好友”。
  async remove(ownerDeviceId: string, peerDeviceId: string) {
    const removed = await this.friendships.disconnect(ownerDeviceId, peerDeviceId);
    this.logger.log(`[Friend] action=remove ownerDeviceId=${ownerDeviceId} peerDeviceId=${peerDeviceId} rows=${removed}`);
  }

  isFriend(ownerDeviceId: string, peerDeviceId: string) {
    return this.friendships.isFriend(ownerDeviceId, peerDeviceId);
  }
}
