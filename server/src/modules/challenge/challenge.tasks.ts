import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';

import { DistributedLock } from 'src/common/redis/redis.module';
import { challengeBestKeepDays, challengeRunKeepDays, challengeSweepBatch, cleanupBatch } from 'src/common/relay_limits';
import { ChallengeRepository } from 'src/modules/challenge/challenge.repository';
import { ChallengeService } from 'src/modules/challenge/challenge.service';

// 挑战的定时任务（多实例抢分布式锁，工作量有界）：
// - 每 5 分钟结算到点没交的局（服务器计时不暂停，用户不回来也照样记分），每轮最多 10 批、每批 challengeSweepBatch 局；
// - 每小时删结束满 30 天的局与挑战结束满 400 天的最好成绩，每轮最多 20 批、每批 1000 行。
@Injectable()
export class ChallengeTasks {
  private readonly logger = new Logger('ChallengeTasks');

  constructor(
    private readonly lock: DistributedLock,
    private readonly challenges: ChallengeService,
    private readonly runs: ChallengeRepository,
  ) {}

  // 只比较 UTC 绝对时刻，显式按 UTC 调度。
  @Cron('0 */5 * * * *', { timeZone: 'UTC' })
  async settle() {
    await this.guard('challenge_settle', 4 * 60, async () => {
      let settled = 0;
      for (let round = 0; round < 10; round++) {
        const batch = await this.challenges.settleDue(Date.now());
        settled += batch;
        if (batch < challengeSweepBatch) break;
      }
      if (settled > 0) this.logger.log(`[ChallengeTasks] action=settle runs=${settled}`);
    });
  }

  @Cron('0 37 * * * *', { timeZone: 'UTC' })
  async retain() {
    await this.guard('challenge_retention', 50 * 60, () => this.sweep());
  }

  async sweep(now = Date.now()) {
    let runs = 0, best = 0;
    for (let round = 0; round < 20; round++) {
      const batch = await this.runs.deleteRunsBefore(new Date(now - challengeRunKeepDays * 86400_000), cleanupBatch);
      runs += batch;
      if (batch < cleanupBatch) break;
    }
    for (let round = 0; round < 20; round++) {
      const batch = await this.runs.deleteBestBefore(new Date(now - challengeBestKeepDays * 86400_000), cleanupBatch);
      best += batch;
      if (batch < cleanupBatch) break;
    }
    this.logger.log(`[ChallengeTasks] action=sweep runs=${runs} best=${best}`);
  }

  private async guard(name: string, ttlSeconds: number, task: () => Promise<void>) {
    try {
      await this.lock.run(name, ttlSeconds, task);
    } catch (error) {
      console.error(error);
      this.logger.error(`[ChallengeTasks] action=${name} errorType=${error instanceof Error ? error.constructor.name : typeof error}`);
    }
  }
}
