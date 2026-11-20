import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 账号的积分时长券（规则见 pass.service.ts）：一个账号一种券一行，到期时刻与累计付的积分；随账号删除，到期满 30 天删除。
@Entity('account_pass')
export class AccountPassEntity extends BaseEntity {
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'pass_id', type: 'varchar', length: 64 }) passId: string;
  @Column({ name: 'expire_time', type: 'datetime', precision: 3 }) expireTime: Date;
  @Column({ name: 'paid', type: 'int', unsigned: true }) paid: number;
}
