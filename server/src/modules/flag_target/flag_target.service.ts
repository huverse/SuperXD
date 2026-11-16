import { HttpStatus, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { EntityManager } from 'typeorm';

import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { cleanupBatch, flagTargetLimit, flagTargetReadPerDevicePerHour } from 'src/common/relay_limits';
import { AccountRepository } from 'src/modules/account/account.repository';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';
import { FlagTargetRepository } from 'src/modules/flag_target/flag_target.repository';
import * as dtos from 'src/modules/flag_target/flag_target.dto';

// 灰度点名（人工决策见客户端 lib/domain/rollout.dart 的 11-16 那条）：名单由管理命令 flag_admin 写在 rollout_target，
// 登录着应用账号的手机签名来问「我被点名了哪些」，只回这个账号没过期的；撤销即删行，手机下次来问就没了。随账号删除，过期的每天清。
@Injectable()
export class FlagTargetService implements OnModuleInit {
  private readonly logger = new Logger('FlagTarget');

  constructor(
    private readonly targets: FlagTargetRepository,
    private readonly accounts: AccountRepository,
    private readonly hooks: AccountDataHooks,
    private readonly limiter: RateLimiter,
  ) {}

  onModuleInit() {
    this.hooks.register((manager, accountIds) => this.deleteAccountsIn(manager, accountIds));
  }

  deleteAccountsIn(manager: EntityManager, accountIds: string[]) {
    return this.targets.deleteAccounts(manager, accountIds);
  }

  async mine(deviceId: string, now = new Date()): Promise<dtos.FlagTargetsDto> {
    const retryAfter = await this.limiter.hit('flag_target_read', deviceId, flagTargetReadPerDevicePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '查询过于频繁', { retryAfter });
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    const rows = await this.targets.activeOf(accountId, now, flagTargetLimit);
    return { flags: rows.map((row) => ({ id: row.flagId, until: row.expiresAt?.toISOString() ?? null })) };
  }

  // 过期的分批删，每轮最多 20 批。
  async sweep(now = new Date()) {
    let removed = 0;
    for (let round = 0; round < 20; round++) {
      const count = await this.targets.deleteExpired(now, cleanupBatch);
      removed += count;
      if (count < cleanupBatch) break;
    }
    this.logger.log(`[FlagTarget] action=sweep removed=${removed}`);
  }
}
