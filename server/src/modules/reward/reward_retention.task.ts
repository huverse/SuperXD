import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { cleanupBatch, rewardKeepDays } from 'src/common/relay_limits';
import { RewardRepository } from 'src/modules/reward/reward.repository';

// 节日抽奖的保留：活动结束 30 天后连同奖品与抽签记录分批删除（参与号哈希、活跃天数与发奖记录只留到这时，供维护者对账与回应询问）。
// 多实例抢分布式锁，全局只跑一份；每轮最多 20 批、每批 1000 行，单次运行工作量有界，剩下的下一轮继续。
@Injectable()
export class RewardRetentionTask {
  private readonly logger = new Logger('RewardRetention');

  constructor(
    private readonly lock: DistributedLock,
    private readonly rewards: RewardRepository,
  ) {}

  // 每小时一次，只比较 UTC 绝对时刻，显式按 UTC 调度。
  @Cron('0 7 * * * *', { timeZone: 'UTC' })
  async run() {
    try {
      await this.lock.run('reward_retention', 50 * 60, () => this.sweep());
    } catch (error) {
      console.error(error);
      this.logger.error('[RewardRetention] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }

  async sweep() {
    const before = new Date(Date.now() - rewardKeepDays * 86400_000);
    let removed = 0;
    for (let round = 0; round < 20; round++) {
      const batch = await this.rewards.deleteEnded(before, cleanupBatch);
      removed += batch;
      if (batch < cleanupBatch) break;
    }
    this.logger.log(`[RewardRetention] action=sweep removedRows=${removed}`);
  }
}
