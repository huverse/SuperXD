import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 节日抽奖的三张表（sql/schema.sql），表间只靠编号在代码里关联，不建外键。概率模型见 reward_odds.ts。
@Entity('reward_campaign')
export class RewardCampaignEntity extends BaseEntity {
  @Column({ name: 'campaign_key', type: 'varchar', length: 64 }) campaignKey: string;
  @Column({ name: 'starts_at', type: 'datetime', precision: 3 }) startsAt: Date;
  @Column({ name: 'ends_at', type: 'datetime', precision: 3 }) endsAt: Date;
  @Column({ name: 'mode', type: 'varchar', length: 16 }) mode: string;
  // DECIMAL 按字符串读回（bigNumberStrings），用到时再转数。
  @Column({ name: 'base_chance', type: 'decimal', precision: 7, scale: 6 }) baseChance: string;
  @Column({ name: 'max_weight', type: 'decimal', precision: 5, scale: 2 }) maxWeight: string;
}

@Entity('reward_prize')
export class RewardPrizeEntity extends BaseEntity {
  @Column({ name: 'campaign_id', type: 'bigint', unsigned: true }) campaignId: string;
  @Column({ name: 'kind', type: 'varchar', length: 16 }) kind: string;
  @Column({ name: 'content', type: 'varchar', length: 1024 }) content: string;
  @Column({ name: 'note', type: 'varchar', length: 200 }) note: string;
  @Column({ name: 'draw_id', type: 'bigint', unsigned: true, nullable: true }) drawId: string | null;
}

@Entity('reward_draw')
export class RewardDrawEntity extends BaseEntity {
  @Column({ name: 'campaign_id', type: 'bigint', unsigned: true }) campaignId: string;
  // 抽签设备的设备号的 sha256 十六进制（2026-11-10 起，见 reward_odds.ts 的人工决策）；列名与 sql 里的注释沿用最初的「参与号」，表结构不变。
  @Column({ name: 'participant_hash', type: 'char', length: 64 }) participantHash: string;
  @Column({ name: 'active_days', type: 'tinyint', unsigned: true }) activeDays: number;
  @Column({ name: 'weight', type: 'decimal', precision: 5, scale: 2 }) weight: string;
  @Column({ name: 'chance', type: 'decimal', precision: 7, scale: 6 }) chance: string;
  @Column({ name: 'prize_id', type: 'bigint', unsigned: true, nullable: true }) prizeId: string | null;
}
