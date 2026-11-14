import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 账号记过的解锁（规则见 unlock_rules.ts）：花积分买的（source buy，price 是付的积分）与抽签抽中的（source drawn，price 为 0），一个账号一项一行；
// 随账号删除；服务公开 30 天后、或下架退回积分后删除。
@Entity('account_unlock')
export class AccountUnlockEntity extends BaseEntity {
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'unlock_id', type: 'varchar', length: 64 }) unlockId: string;
  @Column({ name: 'source', type: 'varchar', length: 8 }) source: string;
  @Column({ name: 'price', type: 'int', unsigned: true }) price: number;
}
