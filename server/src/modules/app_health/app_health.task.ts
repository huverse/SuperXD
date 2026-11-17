import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { AppHealthService } from 'src/modules/app_health/app_health.service';

// 每小时看一次要不要暂停、清一次过期的汇总与意见；多实例抢分布式锁。
@Injectable()
export class AppHealthTask {
  private readonly logger = new Logger('AppHealthTask');

  constructor(
    private readonly lock: DistributedLock,
    private readonly health: AppHealthService,
  ) {}

  // 只比较 UTC 绝对时刻与业务时区的日期，显式按 UTC 调度。
  @Cron('0 23 * * * *', { timeZone: 'UTC' })
  async run() {
    try {
      await this.lock.run('app_health', 50 * 60, async () => {
        await this.health.watch();
        await this.health.sweep();
      });
    } catch (error) {
      console.error(error);
      this.logger.error('[AppHealthTask] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }
}
