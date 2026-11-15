import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { accountIdleDays, accountTombstoneDays, cleanupBatch } from 'src/common/relay_limits';
import { AccountRepository } from 'src/modules/account/account.repository';

// 应用账号的保留：400 天没有任何活跃（登录、查看、账号下任一设备的签名请求）的账号，连同密钥登记与账号下的数据删除（同设备的不活跃清理）；
// 注销时记的墓碑满 accountTombstoneDays 天删除。密钥登记另随设备删除（pairing 编排）。多实例抢分布式锁，每轮各最多 20 批、每批 1000 个（账号每 10 个一个事务），工作量有界。
@Injectable()
export class AccountRetentionTask {
  private readonly logger = new Logger('AccountRetention');

  constructor(
    private readonly lock: DistributedLock,
    private readonly accounts: AccountRepository,
  ) {}

  // 每小时一次，只比较 UTC 绝对时刻，显式按 UTC 调度。
  @Cron('0 17 * * * *', { timeZone: 'UTC' })
  async run() {
    try {
      await this.lock.run('account_retention', 50 * 60, () => this.sweep());
    } catch (error) {
      console.error(error);
      this.logger.error('[AccountRetention] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }

  async sweep() {
    const before = new Date(Date.now() - accountIdleDays * 86400_000);
    let removed = 0;
    for (let round = 0; round < 20; round++) {
      const batch = await this.accounts.deleteIdle(before, cleanupBatch);
      removed += batch;
      if (batch < cleanupBatch) break;
    }
    const tombstoneBefore = new Date(Date.now() - accountTombstoneDays * 86400_000);
    let tombstones = 0;
    for (let round = 0; round < 20; round++) {
      const batch = await this.accounts.deleteTombstones(tombstoneBefore, cleanupBatch);
      tombstones += batch;
      if (batch < cleanupBatch) break;
    }
    this.logger.log(`[AccountRetention] action=sweep removedAccounts=${removed} removedTombstones=${tombstones}`);
  }
}
