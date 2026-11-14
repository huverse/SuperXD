import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { UnlockService } from 'src/modules/unlock/unlock.service';

// 解锁的退回与保留（规则见 unlock_rules.ts）：每小时一次，多实例抢分布式锁，每轮最多 20 批、每批 1000 行。
@Injectable()
export class UnlockTask {
  private readonly logger = new Logger('UnlockTask');

  constructor(
    private readonly lock: DistributedLock,
    private readonly unlocks: UnlockService,
  ) {}

  // 只比较 UTC 绝对时刻，显式按 UTC 调度。
  @Cron('0 33 * * * *', { timeZone: 'UTC' })
  async run() {
    try {
      await this.lock.run('unlock_retention', 50 * 60, () => this.unlocks.sweep());
    } catch (error) {
      console.error(error);
      this.logger.error('[UnlockTask] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }
}
