import { HttpStatus, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { EntityManager } from 'typeorm';

import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { pointsEntriesPage, pointsExpiringDays, pointsLifetimeMonths, pointsReadPerDevicePerHour } from 'src/common/relay_limits';
import { AccountRepository } from 'src/modules/account/account.repository';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';
import { PointsRepository } from 'src/modules/points/points.repository';
import * as dtos from 'src/modules/points/points.dto';

// 积分账本。
// [人工决策-2026-11-12 21:00:20] 用户 11-12 选定的长期规则：积分属于应用账号；每笔获得满 12 个月过期，花的时候先扣快过期的；
// 流水只增、满 13 个月删除；同一挑战重复挑战只补最好成绩的差额（在挑战模块结算时算好再来记）。挑战是获得积分的方式之一，以后的来源
// （活动、任务）与用途（解锁服务、内测资格加权、红包加权）都按「来源 + 幂等键」记一笔，用途等用户点名再做，影响真钱的加权都封顶。
@Injectable()
export class PointsService implements OnModuleInit {
  private readonly logger = new Logger('Points');

  constructor(
    private readonly points: PointsRepository,
    private readonly accounts: AccountRepository,
    private readonly hooks: AccountDataHooks,
    private readonly limiter: RateLimiter,
  ) {}

  onModuleInit() {
    this.hooks.register((manager, accountIds) => this.points.deleteAccounts(manager, accountIds));
  }

  // 获得一笔（调用方事务内；同一来源同一个键只记一次）：满 12 个月过期。
  async grantIn(manager: EntityManager, accountId: string, amount: number, source: string, sourceKey: string, note: string, now: Date) {
    if (amount <= 0) return false;
    const expireTime = new Date(now);
    expireTime.setUTCMonth(expireTime.getUTCMonth() + pointsLifetimeMonths);
    const granted = await this.points.grant(manager, { accountId, amount, source, sourceKey, note, now, expireTime });
    this.logger.log(`[Points] action=grant source=${source} amount=${amount} granted=${granted}`);
    return granted;
  }

  async summary(deviceId: string): Promise<dtos.PointsSummaryDto> {
    const accountId = await this.accountOf(deviceId);
    const now = new Date();
    const balance = await this.points.balanceOf(accountId, now, new Date(now.getTime() + pointsExpiringDays * 86400_000));
    return { balance: balance.balance, expiring: balance.expiring, expiringAt: balance.expiringAt?.getTime() ?? null, serverTime: now.getTime() };
  }

  async entries(deviceId: string, before: string | undefined): Promise<dtos.PointsEntriesDto> {
    const accountId = await this.accountOf(deviceId);
    const rows = await this.points.entriesOf(accountId, before ?? null, pointsEntriesPage + 1);
    const page = rows.slice(0, pointsEntriesPage);
    return {
      entries: page.map((row) => ({ id: row.id, kind: row.kind, amount: row.amount, note: row.note, at: row.createTime.getTime() })),
      next: rows.length > pointsEntriesPage ? page[page.length - 1].id : null,
    };
  }

  private async accountOf(deviceId: string) {
    const retryAfter = await this.limiter.hit('points_read', deviceId, pointsReadPerDevicePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '查询过于频繁', { retryAfter });
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    return accountId;
  }
}
