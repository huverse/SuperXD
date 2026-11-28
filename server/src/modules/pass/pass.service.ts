import { readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { HttpStatus, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';
import { EntityManager } from 'typeorm';

import { env } from 'src/config/env';
import { rateSubjectOf } from 'src/common/client_ip';
import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { cleanupBatch, passBuyPerAccountPerHour, passFileMaxBytes, passKeepDaysAfterExpire, passOffersPerHour, passReadPerDevicePerHour } from 'src/common/relay_limits';
import { AccountRepository } from 'src/modules/account/account.repository';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';
import { PointsService } from 'src/modules/points/points.service';
import { PassRepository } from 'src/modules/pass/pass.repository';
import * as dtos from 'src/modules/pass/pass.dto';

// [人工决策-2026-11-19 22:42:37] 积分时长券（用户选「有效期」，见客户端 lib/toolbox/cinema/cinema_service.dart 文件头；预接好、不启用）：
// 发布目录的 passes.json 写哪些服务要用积分换时长、多少积分换几天，不放文件或没写这项就不收（现在的状态，灰度用户都能用）；
// 花积分与续期同一事务，到期时刻 = max(现在, 原到期) + 天数（续买往后叠加），只认服务器时刻；券从 passes.json 拿掉就是不再收这项，已买的不退也不用退（谁都能用了）。
// 客户端在本机按同一规则显示与拦（开源，挡不住改过的客户端；积分不是钱，按「碰真钱才封顶」的口径接受）。
@Injectable()
export class PassService implements OnModuleInit {
  private readonly logger = new Logger('Pass');
  private cache: { mtimeMs: number; size: number; offers: dtos.PassOfferDto[] } | undefined;

  constructor(
    private readonly passes: PassRepository,
    private readonly accounts: AccountRepository,
    private readonly hooks: AccountDataHooks,
    private readonly points: PointsService,
    private readonly limiter: RateLimiter,
  ) {}

  onModuleInit() {
    this.hooks.register((manager, accountIds) => this.deleteAccountsIn(manager, accountIds));
  }

  // 删这些账号的券（调用方事务内）：注销账号与「删除游乐场与积分」共用。
  deleteAccountsIn(manager: EntityManager, accountIds: string[]) {
    return this.passes.deleteAccounts(manager, accountIds);
  }

  // 公开的券清单（免签名、不带标识，没登录的客户端也要知道哪些服务要换）。
  async offers(ip: string): Promise<dtos.PassOffersDto> {
    const retryAfter = await this.limiter.hit('pass_offers', rateSubjectOf(ip), passOffersPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '请求过于频繁', { retryAfter });
    return { offers: await this.current() };
  }

  async state(deviceId: string): Promise<dtos.PassStateDto> {
    const retryAfter = await this.limiter.hit('pass_read', deviceId, passReadPerDevicePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '查询过于频繁', { retryAfter });
    return this.stateOf(await this.accountOf(deviceId));
  }

  async buy(deviceId: string, passId: string): Promise<dtos.PassStateDto> {
    const accountId = await this.accountOf(deviceId);
    const retryAfter = await this.limiter.hit('pass_buy', accountId, passBuyPerAccountPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '操作过于频繁', { retryAfter });
    const offer = (await this.current()).find((item) => item.id === passId);
    if (offer === undefined) throw new RelayError(RelayCode.passUnavailable, HttpStatus.CONFLICT, '这项服务现在不用积分换时长');
    const now = new Date();
    const expire = await this.passes.extend(accountId, passId, offer.price, offer.days, now, this.accounts.hold, (manager, ref) => this.points.spendIn(manager, accountId, offer.price, ref, `时长 · ${offer.title}`, now));
    this.logger.log(`[Pass] action=buy pass=${passId} price=${offer.price} days=${offer.days} until=${expire.toISOString()}`);
    return this.stateOf(accountId);
  }

  // 定时任务：到期满 passKeepDaysAfterExpire 天的删掉（按到期时刻的索引分批）。
  async sweep(now = new Date()) {
    const before = new Date(now.getTime() - passKeepDaysAfterExpire * 86400_000);
    let removed = 0;
    for (let round = 0; round < 20; round++) {
      const batch = await this.passes.deleteExpired(before, cleanupBatch);
      removed += batch;
      if (batch < cleanupBatch) break;
    }
    this.logger.log(`[Pass] action=sweep removed=${removed}`);
  }

  private async stateOf(accountId: string): Promise<dtos.PassStateDto> {
    const now = Date.now();
    const held = await this.passes.heldOf(accountId, new Date(now));
    return { held: held.map((row) => ({ id: row.passId, until: row.expireTime.getTime() })), serverTime: now };
  }

  // 发布目录的 passes.json：还没放文件时为空（都不收）；写坏了抛错、不往外发（买与看清单都回 INTERNAL）。按修改时间与大小缓存，换文件即生效。
  private async current(): Promise<dtos.PassOfferDto[]> {
    const path = join(env().releasesDir, 'passes.json');
    let info: Awaited<ReturnType<typeof stat>>;
    try {
      info = await stat(path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      this.cache = undefined;
      return [];
    }
    const cached = this.cache;
    if (cached !== undefined && cached.mtimeMs === info.mtimeMs && cached.size === info.size) return cached.offers;
    if (info.size > passFileMaxBytes) throw new Error(`passes.json 超过 ${passFileMaxBytes} 字节`);
    const file = plainToInstance(dtos.PassOffersDto, JSON.parse(await readFile(path, 'utf8')) as object);
    const errors = validateSync(file, { whitelist: true, forbidNonWhitelisted: true });
    if (errors.length > 0) throw new Error(`passes.json 格式不对：${errors.map((item) => item.property).join(',')}`);
    if (new Set(file.offers.map((offer) => offer.id)).size !== file.offers.length) throw new Error('passes.json 的编号重复');
    this.cache = { mtimeMs: info.mtimeMs, size: info.size, offers: file.offers };
    this.logger.log(`[Pass] action=load offers=${file.offers.length}`);
    return file.offers;
  }

  private async accountOf(deviceId: string) {
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    return accountId;
  }
}
