import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { FlagTargetService } from 'src/modules/flag_target/flag_target.service';

// 过期的灰度点名每天清一次，多实例抢分布式锁。
@Injectable()
export class FlagTargetTask {
  private readonly logger = new Logger('FlagTargetTask');

  constructor(
    private readonly lock: DistributedLock,
    private readonly targets: FlagTargetService,
  ) {}

  // 只比较 UTC 绝对时刻，显式按 UTC 调度。
  @Cron('0 41 3 * * *', { timeZone: 'UTC' })
  async run() {
    try {
      await this.lock.run('flag_target_retention', 50 * 60, () => this.targets.sweep());
    } catch (error) {
      console.error(error);
      this.logger.error('[FlagTargetTask] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }
}
