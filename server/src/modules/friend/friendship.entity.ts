import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 好友关系按方向各存一行（owner → peer），双方互为好友时有两行。
@Entity('friendship')
export class FriendshipEntity extends BaseEntity {
  @Column({ name: 'owner_device_id', type: 'varchar', length: 32 }) ownerDeviceId: string;
  @Column({ name: 'peer_device_id', type: 'varchar', length: 32 }) peerDeviceId: string;
}
