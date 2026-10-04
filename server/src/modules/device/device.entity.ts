import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

@Entity('device')
export class DeviceEntity extends BaseEntity {
  @Column({ name: 'device_id', type: 'varchar', length: 32 }) deviceId: string;
  @Column({ name: 'sign_public_key', type: 'varchar', length: 64 }) signPublicKey: string;
  @Column({ name: 'box_public_key', type: 'varchar', length: 64 }) boxPublicKey: string;
  @Column({ name: 'last_seen_time', type: 'datetime', precision: 3 }) lastSeenTime: Date;
}
