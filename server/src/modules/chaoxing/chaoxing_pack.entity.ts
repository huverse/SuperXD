import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 代签凭据包的临时信箱：只存客户端用一次性密钥加过密的包，服务端看不到内容，也没有解密用的密钥。
@Entity('chaoxing_pack')
export class ChaoxingPackEntity extends BaseEntity {
  @Column({ name: 'pickup_id', type: 'varchar', length: 32 }) pickupId: string;
  @Column({ name: 'data', type: 'varbinary', length: 2048 }) data: Buffer;
  @Column({ name: 'bytes', type: 'int', unsigned: true }) bytes: number;
  @Column({ name: 'expire_time', type: 'datetime', precision: 3 }) expireTime: Date;
}
