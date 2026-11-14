import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 好友关系按方向各存一行（owner → peer），双方互为好友时有两行。
// moved_from：对方的私信换到了新设备（应用账号接管，见 pairing/social_binding.service.ts），这一行改挂新设备并记下 owner 还认得的旧设备号，owner 的客户端处理完确认后清空。
@Entity('friendship')
export class FriendshipEntity extends BaseEntity {
  @Column({ name: 'owner_device_id', type: 'varchar', length: 32 }) ownerDeviceId: string;
  @Column({ name: 'peer_device_id', type: 'varchar', length: 32 }) peerDeviceId: string;
  @Column({ name: 'moved_from', type: 'varchar', length: 32, nullable: true }) movedFrom: string | null;
}
