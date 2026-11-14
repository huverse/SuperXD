import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { cleanupBatch, diagnosticKeepDays } from 'src/common/relay_limits';
import { DiagnosticStore } from 'src/modules/diagnostic/diagnostic.store';
import { DiagnosticUploadRepository } from 'src/modules/diagnostic/diagnostic_upload.repository';

// 诊断包的保留：上传满 30 天的包与中途断掉留下的残片删掉，再按目录实际重写已用量（Redis 里预占的数会因断开、重启略有出入，每轮校正）。
// 认领到应用账号的记录随包一起删；认领后超过保留期一天还在的（文件被别处删掉、没对上）兜底按时刻删，每轮最多 20 批。
// 多实例抢分布式锁，全局只跑一份；目录里的文件数有上限（relay_limits.ts 的 diagnosticStoreMaxFiles），每轮工作量有界。
@Injectable()
export class DiagnosticRetentionTask {
  private readonly logger = new Logger('DiagnosticRetention');

  constructor(
    private readonly lock: DistributedLock,
    private readonly store: DiagnosticStore,
    private readonly uploads: DiagnosticUploadRepository,
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
    const now = Date.now();
    const { removed, files, bytes } = await this.store.sweep(now);
    await this.uploads.forget(removed);
    const before = new Date(now - (diagnosticKeepDays + 1) * 86400_000);
    let stale = 0;
    for (let round = 0; round < 20; round++) {
      const deleted = await this.uploads.deleteBefore(before, cleanupBatch);
      stale += deleted;
      if (deleted < cleanupBatch) break;
    }
    this.logger.log(`[DiagnosticRetention] action=sweep removed=${removed.length} files=${files} bytes=${bytes} staleClaims=${stale}`);
  }
}
