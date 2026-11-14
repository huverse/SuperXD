import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { cleanupBatch, pointsEntryKeepDays, pointsSpentGrantKeepDays } from 'src/common/relay_limits';
import { PointsRepository } from 'src/modules/points/points.repository';

// 积分的到期与保留（人工决策见 points.service.ts）：每小时把到期还有剩余的获得清零并记过期流水；流水满 13 个月删除；
// 剩余为 0 且过期满 30 天的获得行删除（余额只看没过期的，删了不影响）。多实例抢分布式锁，每轮最多 20 批、每批 1000 行，工作量有界。
@Injectable()
export class PointsRetentionTask {
  private readonly logger = new Logger('PointsRetention');

  constructor(
    private readonly lock: DistributedLock,
    private readonly points: PointsRepository,
  ) {}

  // 每小时一次，只比较 UTC 绝对时刻，显式按 UTC 调度。
  @Cron('0 27 * * * *', { timeZone: 'UTC' })
  async run() {
    try {
      await this.lock.run('points_retention', 50 * 60, () => this.sweep());
    } catch (error) {
      console.error(error);
      this.logger.error('[PointsRetention] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }

  async sweep(now = new Date()) {
    const counts = { expired: 0, entries: 0, grants: 0 };
    const steps: [keyof typeof counts, () => Promise<number>][] = [
      ['expired', () => this.points.expireDue(now, cleanupBatch)],
      ['entries', () => this.points.deleteEntriesBefore(new Date(now.getTime() - pointsEntryKeepDays * 86400_000), cleanupBatch)],
      ['grants', () => this.points.deleteGrantsBefore(new Date(now.getTime() - pointsSpentGrantKeepDays * 86400_000), cleanupBatch)],
    ];
    for (const [name, step] of steps) {
      for (let round = 0; round < 20; round++) {
        const batch = await step();
        counts[name] += batch;
        if (batch < cleanupBatch) break;
      }
    }
    this.logger.log(`[PointsRetention] action=sweep expired=${counts.expired} entries=${counts.entries} grants=${counts.grants}`);
  }
}
