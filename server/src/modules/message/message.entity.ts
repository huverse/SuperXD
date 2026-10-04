import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 信箱里的一条端到端密文；服务端看不到内容，只知道收发双方、大小与时间。
@Entity('message')
export class MessageEntity extends BaseEntity {
  @Column({ name: 'recipient_device_id', type: 'varchar', length: 32 }) recipientDeviceId: string;
  @Column({ name: 'sender_device_id', type: 'varchar', length: 32 }) senderDeviceId: string;
  @Column({ name: 'client_id', type: 'varchar', length: 36 }) clientId: string;
  @Column({ name: 'envelope', type: 'mediumblob' }) envelope: Buffer;
  @Column({ name: 'expire_time', type: 'datetime', precision: 3 }) expireTime: Date;
}
