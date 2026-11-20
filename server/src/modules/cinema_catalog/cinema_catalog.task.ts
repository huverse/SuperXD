import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { cinemaCatalogLockSeconds } from 'src/common/relay_limits';
import { CinemaCatalogService } from 'src/modules/cinema_catalog/cinema_catalog.service';

// 片名目录的抓取（规则见 cinema_catalog.service.ts）：每小时一次，多实例抢分布式锁；一轮按时间预算跑，锁的时限见 relay_limits.ts 的 cinemaCatalogLockSeconds。
@Injectable()
export class CinemaCatalogTask {
  private readonly logger = new Logger('CinemaCatalogTask');

  constructor(
    private readonly lock: DistributedLock,
    private readonly catalog: CinemaCatalogService,
  ) {}

  @Cron('0 17 * * * *', { timeZone: 'UTC' })
  async run() {
    try {
      await this.lock.run('cinema_catalog', cinemaCatalogLockSeconds, () => this.catalog.sync());
    } catch (error) {
      console.error(error);
      this.logger.error('[CinemaCatalogTask] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }
}
