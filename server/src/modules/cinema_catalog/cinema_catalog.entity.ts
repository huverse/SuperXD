import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 片名目录（规则见 cinema_catalog.service.ts）：每个源每部片一行，只有编号与片名的折叠写法（源上公开的目录，不含用户信息）。
@Entity('cinema_catalog')
export class CinemaCatalogEntity extends BaseEntity {
  @Column({ name: 'rule_id', type: 'varchar', length: 32 }) ruleId: string;
  @Column({ name: 'source', type: 'varchar', length: 64 }) source: string;
  @Column({ name: 'folded', type: 'varchar', length: 255 }) folded: string;
}

// 每个源的抓取进度：抓全的这一轮从什么时刻起、抓到第几页，增量补到的时刻。
@Entity('cinema_catalog_state')
export class CinemaCatalogStateEntity extends BaseEntity {
  @Column({ name: 'rule_id', type: 'varchar', length: 32 }) ruleId: string;
  @Column({ name: 'crawl_started', type: 'datetime', precision: 3, nullable: true }) crawlStarted: Date | null;
  @Column({ name: 'crawl_page', type: 'int', unsigned: true }) crawlPage: number;
  @Column({ name: 'synced_at', type: 'datetime', precision: 3, nullable: true }) syncedAt: Date | null;
}
