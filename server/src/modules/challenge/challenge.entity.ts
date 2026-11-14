import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 挑战的一局：计划（关卡图、题面、钥匙、计分参数快照）与进度都以 JSON 文本存在这一行，交答案时锁这一行改。
// active 进行中为 1、结算后为空，(account_id, active) 唯一，所以一个账号同时只有一局进行中（并发开局只有一个插得进）。
@Entity('challenge_run')
export class ChallengeRunEntity extends BaseEntity {
  @Column({ name: 'run_id', type: 'varchar', length: 32 }) runId: string;
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'challenge_id', type: 'varchar', length: 64 }) challengeId: string;
  @Column({ name: 'active', type: 'tinyint', nullable: true }) active: number | null;
  @Column({ name: 'deadline', type: 'datetime', precision: 3 }) deadline: Date;
  @Column({ name: 'plan', type: 'mediumtext' }) plan: string;
  @Column({ name: 'progress', type: 'text' }) progress: string;
  // 结束方式：cleared 全过、stuck 剩下的开不了、timeout 到点、ended 玩家提前结束。
  @Column({ name: 'ending', type: 'varchar', length: 8, nullable: true }) ending: string | null;
  @Column({ name: 'points', type: 'int', unsigned: true, nullable: true }) points: number | null;
  @Column({ name: 'awarded', type: 'int', unsigned: true, nullable: true }) awarded: number | null;
  @Column({ name: 'end_time', type: 'datetime', precision: 3, nullable: true }) endTime: Date | null;
}

// 每个账号每个挑战的最好成绩：重复挑战只补超过它的差额；挑战结束 400 天后删除。
@Entity('challenge_best')
export class ChallengeBestEntity extends BaseEntity {
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'challenge_id', type: 'varchar', length: 64 }) challengeId: string;
  @Column({ name: 'points', type: 'int', unsigned: true }) points: number;
  @Column({ name: 'run_id', type: 'varchar', length: 32 }) runId: string;
  @Column({ name: 'ends_at', type: 'datetime', precision: 3 }) endsAt: Date;
}
