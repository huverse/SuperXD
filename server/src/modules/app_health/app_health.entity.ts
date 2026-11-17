import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 健康回报的按日汇总（规则见 app_health_rules.ts）：渠道、平台、版本、校园日各一行，只有两个计数，不存原始回报；保留 healthKeepDays 天。
@Entity('app_health_daily')
export class AppHealthDailyEntity extends BaseEntity {
  @Column({ name: 'channel', type: 'varchar', length: 32 }) channel: string;
  @Column({ name: 'platform', type: 'varchar', length: 8 }) platform: string;
  @Column({ name: 'version_code', type: 'int', unsigned: true }) versionCode: number;
  @Column({ name: 'day', type: 'date' }) day: string;
  @Column({ name: 'reports', type: 'int', unsigned: true }) reports: number;
  @Column({ name: 'fatal', type: 'int', unsigned: true }) fatal: number;
}

// 自动暂停：渠道加版本一行；paused 为 1 是停着，维护者解除后为 0（之后不再自动停这一版）。保留 healthPauseKeepDays 天。
@Entity('app_release_pause')
export class AppReleasePauseEntity extends BaseEntity {
  @Column({ name: 'channel', type: 'varchar', length: 32 }) channel: string;
  @Column({ name: 'version_code', type: 'int', unsigned: true }) versionCode: number;
  @Column({ name: 'paused', type: 'tinyint', unsigned: true }) paused: number;
  @Column({ name: 'reason', type: 'varchar', length: 200 }) reason: string;
}

// 新版本的匿名意见：渠道、平台、版本、好或不好、一句话；保留 healthKeepDays 天。
@Entity('app_feedback')
export class AppFeedbackEntity extends BaseEntity {
  @Column({ name: 'channel', type: 'varchar', length: 32 }) channel: string;
  @Column({ name: 'platform', type: 'varchar', length: 8 }) platform: string;
  @Column({ name: 'version_code', type: 'int', unsigned: true }) versionCode: number;
  @Column({ name: 'good', type: 'tinyint', unsigned: true }) good: number;
  @Column({ name: 'text', type: 'varchar', length: 200 }) text: string;
}
