import { HttpStatus, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { EntityManager } from 'typeorm';

import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { cleanupBatch, unlockBuyPerAccountPerHour, unlockKeepDaysAfterPublic, unlockReadPerDevicePerHour } from 'src/common/relay_limits';
import { AccountRepository } from 'src/modules/account/account.repository';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';
import { RolloutUnlockDto } from 'src/modules/app_release/app_release.dto';
import { RolloutSource } from 'src/modules/app_release/rollout_source';
import { PointsService } from 'src/modules/points/points.service';
import { UnlockRepository } from 'src/modules/unlock/unlock.repository';
import { unlockPublic, unlockReason } from 'src/modules/unlock/unlock_rules';
import * as dtos from 'src/modules/unlock/unlock.dto';

// 解锁（人工决策见 unlock_rules.ts）：配置读灰度配置的 unlocks，账号记过的解锁在 account_unlock，花积分与记解锁同一事务；
// 抽签抽中的看状态时顺带记下（之后降级也不踢出）；下架的买过的由清理任务退回积分。
@Injectable()
export class UnlockService implements OnModuleInit {
  private readonly logger = new Logger('Unlock');

  constructor(
    private readonly unlocks: UnlockRepository,
    private readonly accounts: AccountRepository,
    private readonly hooks: AccountDataHooks,
    private readonly points: PointsService,
    private readonly rollouts: RolloutSource,
    private readonly limiter: RateLimiter,
  ) {}

  onModuleInit() {
    this.hooks.register((manager, accountIds) => this.deleteAccountsIn(manager, accountIds));
  }

  // 删这些账号的解锁记录（调用方事务内）：注销账号与「删除游乐场与积分」共用。
  deleteAccountsIn(manager: EntityManager, accountIds: string[]) {
    return this.unlocks.deleteAccounts(manager, accountIds);
  }

  async state(deviceId: string): Promise<dtos.UnlockStateDto> {
    const retryAfter = await this.limiter.hit('unlock_read', deviceId, unlockReadPerDevicePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '查询过于频繁', { retryAfter });
    return this.stateOf(await this.accountOf(deviceId), await this.specs());
  }

  async buy(deviceId: string, unlockId: string): Promise<dtos.UnlockStateDto> {
    const accountId = await this.accountOf(deviceId);
    const retryAfter = await this.limiter.hit('unlock_buy', accountId, unlockBuyPerAccountPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '操作过于频繁', { retryAfter });
    const specs = (await this.rollouts.current()).unlocks ?? [];
    const spec = specs.find((item) => item.id === unlockId);
    const now = new Date();
    if (spec === undefined || spec.retired === true || spec.price === undefined || unlockPublic(spec, now.getTime())) {
      throw new RelayError(RelayCode.unlockUnavailable, HttpStatus.CONFLICT, '这一项不能用积分解锁');
    }
    // 已经能用（等级够、买过或抽中过）就不再扣；同一账号并发来两次只扣一次（唯一键）。
    const level = await this.points.levelOfAccount(accountId);
    const owned = (await this.unlocks.ownedOf(accountId, [unlockId])).has(unlockId);
    if (unlockReason(spec, accountId, level, owned, now.getTime()) === null) {
      const price = spec.price;
      const rowId = await this.unlocks.buy(accountId, unlockId, price, now, this.accounts.hold, (manager, row) => this.points.spendIn(manager, accountId, price, `unlock:${row}`, `解锁 · ${spec.title}`, now));
      this.logger.log(`[Unlock] action=buy unlock=${unlockId} price=${price} bought=${rowId !== null}`);
    }
    return this.stateOf(accountId, specs);
  }

  // 服务端要强制的功能用它核一次（与 state 同一规则，抽中的同样记下）。
  async isOpen(accountId: string, unlockId: string) {
    return (await this.stateOf(accountId, await this.specs())).open.includes(unlockId);
  }

  // 定时任务：下架的买过的退回积分（来源 refund，不算等级）后删记录，抽中的直接删；公开满 30 天的删记录、不退。配置读不了就这一轮不做。
  async sweep(now = new Date()) {
    const specs = (await this.rollouts.current()).unlocks ?? [];
    const titles = new Map(specs.map((spec) => [spec.id, spec.title]));
    const retired = specs.filter((spec) => spec.retired === true).map((spec) => spec.id);
    const expired = specs.filter((spec) => spec.retired !== true && unlockPublic(spec, now.getTime() - unlockKeepDaysAfterPublic * 86400_000)).map((spec) => spec.id);
    const counts = { refunded: 0, removed: 0 };
    for (let round = 0; round < 20; round++) {
      const batch = await this.unlocks.settle(retired, cleanupBatch, this.accounts.holdAll, async (manager, rows) => {
        const refunds = rows
          .filter((row) => row.source === 'buy' && row.price > 0)
          .map((row) => ({ accountId: row.accountId, amount: row.price, sourceKey: `unlock:${row.id}`, note: `退回 · ${titles.get(row.unlockId) ?? row.unlockId}` }));
        await this.points.refundAllIn(manager, refunds, now);
        counts.refunded += refunds.length;
      });
      counts.removed += batch;
      if (batch < cleanupBatch) break;
    }
    for (let round = 0; round < 20; round++) {
      const batch = await this.unlocks.deleteOf(expired, cleanupBatch);
      counts.removed += batch;
      if (batch < cleanupBatch) break;
    }
    this.logger.log(`[Unlock] action=sweep retired=${retired.length} public=${expired.length} refunded=${counts.refunded} removed=${counts.removed}`);
  }

  private async stateOf(accountId: string, specs: RolloutUnlockDto[]): Promise<dtos.UnlockStateDto> {
    const now = Date.now();
    const level = await this.points.levelOfAccount(accountId);
    const owned = await this.unlocks.ownedOf(accountId, specs.map((spec) => spec.id));
    const open: string[] = [];
    const drawn: string[] = [];
    for (const spec of specs) {
      const reason = unlockReason(spec, accountId, level, owned.has(spec.id), now);
      if (reason === null) continue;
      open.push(spec.id);
      if (reason === 'drawn') drawn.push(spec.id);
    }
    await this.unlocks.insertDrawn(accountId, drawn, new Date(now), this.accounts.hold);
    if (drawn.length > 0) this.logger.log(`[Unlock] action=draw unlocks=${drawn.join(',')}`);
    return { level, open, serverTime: now };
  }

  // 看状态时配置读不了按没有解锁算（记错误日志），不挡别的功能；买与清理照常报错。
  private async specs() {
    try {
      return (await this.rollouts.current()).unlocks ?? [];
    } catch (error) {
      console.error(error);
      this.logger.error(`[Unlock] action=specs errorType=${error instanceof Error ? error.constructor.name : typeof error}`);
      return [];
    }
  }

  private async accountOf(deviceId: string) {
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    return accountId;
  }
}
