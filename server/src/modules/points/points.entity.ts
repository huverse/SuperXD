import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 每笔获得一行（人工决策见 points.service.ts）：满 12 个月过期，花的时候先扣快过期的（本阶段还没有花费的入口）；余额 = 没过期的 remaining 之和。
@Entity('points_grant')
export class PointsGrantEntity extends BaseEntity {
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'amount', type: 'int', unsigned: true }) amount: number;
  @Column({ name: 'remaining', type: 'int', unsigned: true }) remaining: number;
  // 来源与幂等键：同一来源同一个键只记一次（挑战是这一局的编号）。
  @Column({ name: 'source', type: 'varchar', length: 16 }) source: string;
  @Column({ name: 'source_key', type: 'varchar', length: 64 }) sourceKey: string;
  @Column({ name: 'expire_time', type: 'datetime', precision: 3 }) expireTime: Date;
}

// 积分流水：只增，满 13 个月删除。kind 是 earn 获得、expire 过期、spend 花费、refund 退回；amount 正数加、负数减。
@Entity('points_entry')
export class PointsEntryEntity extends BaseEntity {
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'kind', type: 'varchar', length: 8 }) kind: string;
  @Column({ name: 'amount', type: 'int' }) amount: number;
  @Column({ name: 'note', type: 'varchar', length: 64 }) note: string;
  @Column({ name: 'ref', type: 'varchar', length: 64 }) ref: string;
}
