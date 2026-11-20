import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { CinemaCatalogService } from 'src/modules/cinema_catalog/cinema_catalog.service';

// 片名目录的抓取（规则见 cinema_catalog.service.ts）：每小时一次，多实例抢分布式锁；抓全最长要半小时上下，锁给两小时。
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
      await this.lock.run('cinema_catalog', 2 * 3600, () => this.catalog.sync());
    } catch (error) {
      console.error(error);
      this.logger.error('[CinemaCatalogTask] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }
}
