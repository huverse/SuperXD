import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { PassService } from 'src/modules/pass/pass.service';

// 时长券的保留（规则见 pass.service.ts）：每小时一次，多实例抢分布式锁，每轮最多 20 批、每批 1000 行。
@Injectable()
export class PassTask {
  private readonly logger = new Logger('PassTask');

  constructor(
    private readonly lock: DistributedLock,
    private readonly passes: PassService,
  ) {}

  // 只比较 UTC 绝对时刻，显式按 UTC 调度。
  @Cron('0 37 * * * *', { timeZone: 'UTC' })
  async run() {
    try {
      await this.lock.run('pass_retention', 50 * 60, () => this.passes.sweep());
    } catch (error) {
      console.error(error);
      this.logger.error('[PassTask] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }
}
