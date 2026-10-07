import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { cleanupBatch } from 'src/common/relay_limits';
import { ChaoxingPackRepository } from 'src/modules/chaoxing/chaoxing_pack.repository';

// 代签凭据包的保留：过期没取走的包分批删除，由本模块自己负责，不挂在私信的清理任务里。
// 多实例抢分布式锁，全局只跑一份；每轮最多 20 批、每批 1000 行，单次运行工作量有界，剩下的下一轮继续。
@Injectable()
export class ChaoxingPackRetentionTask {
  private readonly logger = new Logger('ChaoxingPackRetention');

  constructor(
    private readonly lock: DistributedLock,
    private readonly packs: ChaoxingPackRepository,
  ) {}

  // 每 10 分钟一次，只比较 UTC 绝对时刻，显式按 UTC 调度。
  @Cron('0 */10 * * * *', { timeZone: 'UTC' })
  async run() {
    try {
      await this.lock.run('chaoxing_pack_retention', 9 * 60, () => this.sweep());
    } catch (error) {
      console.error(error);
      this.logger.error('[ChaoxingPackRetention] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }

  async sweep() {
    const now = new Date();
    let removed = 0;
    for (let round = 0; round < 20; round++) {
      const batch = await this.packs.deleteExpired(now, cleanupBatch);
      removed += batch;
      if (batch < cleanupBatch) break;
    }
    this.logger.log(`[ChaoxingPackRetention] action=sweep expiredPacks=${removed}`);
  }
}
