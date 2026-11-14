import { Injectable, Logger } from '@nestjs/common';

import { DeviceRepository } from 'src/modules/device/device.repository';
import { FriendshipRepository } from 'src/modules/friend/friendship.repository';
import * as dtos from 'src/modules/friend/friend.dto';

@Injectable()
export class FriendService {
  private readonly logger = new Logger('Friend');

  constructor(
    private readonly friendships: FriendshipRepository,
    private readonly devices: DeviceRepository,
  ) {}

  // 换了设备的好友（movedFrom）总带新公钥；withKeys 为真时每个好友都带（新手机接管后拿好友名单用）。好友有上限，查公钥一次 IN 有界。
  async list(ownerDeviceId: string, withKeys: boolean): Promise<dtos.FriendDto[]> {
    const rows = await this.friendships.list(ownerDeviceId);
    const keyed = withKeys ? rows : rows.filter((row) => row.movedFrom !== null);
    const keys = new Map((await this.devices.keysOf(keyed.map((row) => row.peerDeviceId))).map((device) => [device.deviceId, device]));
    return rows.map((row) => {
      const device = keys.get(row.peerDeviceId);
      return {
        deviceId: row.peerDeviceId,
        since: row.createTime.getTime(),
        ...(device === undefined ? {} : { signPublicKey: device.signPublicKey, boxPublicKey: device.boxPublicKey }),
        ...(row.movedFrom === null ? {} : { movedFrom: row.movedFrom }),
      };
    });
  }

  // 双向删除；对方之后发来的消息会被拒收（NOT_FRIEND），对方客户端据此标记“已解除好友”。
  async remove(ownerDeviceId: string, peerDeviceId: string) {
    const removed = await this.friendships.disconnect(ownerDeviceId, peerDeviceId);
    this.logger.log(`[Friend] action=remove ownerDeviceId=${ownerDeviceId} peerDeviceId=${peerDeviceId} rows=${removed}`);
  }

  async ackMoves(ownerDeviceId: string, peerDeviceIds: string[]) {
    await this.friendships.ackMoves(ownerDeviceId, peerDeviceIds);
    this.logger.log(`[Friend] action=ack_moves ownerDeviceId=${ownerDeviceId} count=${peerDeviceIds.length}`);
  }

  isFriend(ownerDeviceId: string, peerDeviceId: string) {
    return this.friendships.isFriend(ownerDeviceId, peerDeviceId);
  }
}
