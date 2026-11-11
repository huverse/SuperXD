import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { DiagnosticStore } from 'src/modules/diagnostic/diagnostic.store';

// 诊断包的保留：上传满 30 天的包与中途断掉留下的残片删掉，再按目录实际重写已用量（Redis 里预占的数会因断开、重启略有出入，每轮校正）。
// 多实例抢分布式锁，全局只跑一份；目录里的文件数有上限（relay_limits.ts 的 diagnosticStoreMaxFiles），每轮工作量有界。
@Injectable()
export class DiagnosticRetentionTask {
  private readonly logger = new Logger('DiagnosticRetention');

  constructor(
    private readonly lock: DistributedLock,
    private readonly store: DiagnosticStore,
  ) {}

  // 每 10 分钟一次（错开别的清理任务半分钟），只比较 UTC 绝对时刻，显式按 UTC 调度。
  @Cron('30 */10 * * * *', { timeZone: 'UTC' })
  async run() {
    try {
      await this.lock.run('diagnostic_retention', 9 * 60, () => this.sweep());
    } catch (error) {
      console.error(error);
      this.logger.error('[DiagnosticRetention] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }

  async sweep() {
    const { removed, files, bytes } = await this.store.sweep(Date.now());
    this.logger.log(`[DiagnosticRetention] action=sweep removed=${removed} files=${files} bytes=${bytes}`);
  }
}
