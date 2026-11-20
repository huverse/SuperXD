import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { DataSource } from 'typeorm';

import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { leisureDeletePerDevicePerHour } from 'src/common/relay_limits';
import { AccountRepository } from 'src/modules/account/account.repository';
import { ChallengeService } from 'src/modules/challenge/challenge.service';
import { PointsService } from 'src/modules/points/points.service';
import { PassService } from 'src/modules/pass/pass.service';
import { UnlockService } from 'src/modules/unlock/unlock.service';

// 「删除游乐场与积分」（人工决策见客户端 lib/domain/leisure.dart）：删掉这个应用账号的挑战成绩、解锁记录与积分（同一事务，要么都删要么都不删），
// 账号本身、私信、诊断包与节日抽签记录不动。跨三个模块的事归这里调度，三个模块只各自提供「在给定事务里删这些账号的」那一步，不知道有这个开关。
@Injectable()
export class LeisureService {
  private readonly logger = new Logger('Leisure');

  constructor(
    private readonly database: DataSource,
    private readonly accounts: AccountRepository,
    private readonly limiter: RateLimiter,
    private readonly challenges: ChallengeService,
    private readonly unlocks: UnlockService,
    private readonly passes: PassService,
    private readonly points: PointsService,
  ) {}

  async remove(deviceId: string) {
    const retryAfter = await this.limiter.hit('leisure_delete', deviceId, leisureDeletePerDevicePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '删除过于频繁', { retryAfter });
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    await this.database.transaction(async (manager) => {
      await this.challenges.deleteAccountsIn(manager, [accountId]);
      await this.unlocks.deleteAccountsIn(manager, [accountId]);
      await this.passes.deleteAccountsIn(manager, [accountId]);
      await this.points.deleteAccountsIn(manager, [accountId]);
    });
    this.logger.log(`[Leisure] action=delete deviceId=${deviceId}`);
  }
}
