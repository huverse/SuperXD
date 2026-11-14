import { timingSafeEqual } from 'node:crypto';
import { HttpStatus, Inject, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import Redis from 'ioredis';

import { REDIS, RateLimiter } from 'src/common/redis/redis.module';
import { RedisKeys } from 'src/common/redis/redis_keys';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { diagnosticAccountListLimit, diagnosticAccountRequestsPerHour, diagnosticKeepDays } from 'src/common/relay_limits';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';
import { AccountRepository } from 'src/modules/account/account.repository';
import { claimHash } from 'src/modules/diagnostic/diagnostic.service';
import { DiagnosticStore } from 'src/modules/diagnostic/diagnostic.store';
import { DiagnosticUploadRepository, DiagnosticUploadRow } from 'src/modules/diagnostic/diagnostic_upload.repository';
import * as dtos from 'src/modules/diagnostic/diagnostic.dto';

const notFound = () => new RelayError(RelayCode.diagnosticNotFound, HttpStatus.NOT_FOUND, '诊断包不存在或已删除');

const present = (row: DiagnosticUploadRow): dtos.DiagnosticUploadDto => ({
  id: row.diagnosticId,
  bytes: row.bytes,
  uploadedAt: row.createTime.getTime(),
  expiresAt: row.createTime.getTime() + diagnosticKeepDays * 86400_000,
});

// 诊断包认领到应用账号（第 4 阶段，人工决策见客户端 lib/domain/diagnostic_upload.dart）：登录了应用账号的设备凭回执里的口令认领刚传的包，
// 之后能看到、删除自己认领过的包；注销账号时经 AccountDataHooks 在同一事务里删记录、随后删文件。只认应用账号，不认是用什么登录的。
@Injectable()
export class DiagnosticAccountService implements OnModuleInit {
  private readonly logger = new Logger('DiagnosticAccount');

  constructor(
    private readonly limiter: RateLimiter,
    private readonly accounts: AccountRepository,
    private readonly uploads: DiagnosticUploadRepository,
    private readonly store: DiagnosticStore,
    private readonly hooks: AccountDataHooks,
    @Inject(REDIS) private readonly redis: Redis,
  ) {}

  onModuleInit() {
    this.hooks.register(async (manager, accountIds) => this.store.remove(await this.uploads.deleteAccounts(manager, accountIds)));
  }

  async claim(deviceId: string, diagnosticId: string, claim: string): Promise<dtos.DiagnosticUploadDto> {
    const accountId = await this.accountOf(deviceId);
    const saved = await this.redis.get(RedisKeys.diagnosticClaim(diagnosticId));
    const expected = claimHash(claim);
    if (saved === null || saved.length !== expected.length || !timingSafeEqual(Buffer.from(saved), Buffer.from(expected))) throw notFound();
    const bytes = await this.store.size(diagnosticId);
    if (bytes === null) throw notFound();
    const now = new Date();
    if (!(await this.uploads.claim(diagnosticId, accountId, bytes, now))) throw notFound();
    await this.redis.del(RedisKeys.diagnosticClaim(diagnosticId));
    this.logger.log(`[DiagnosticAccount] action=claim id=${diagnosticId} deviceId=${deviceId}`);
    return present({ diagnosticId, bytes, createTime: now });
  }

  async list(deviceId: string): Promise<dtos.DiagnosticUploadListDto> {
    const accountId = await this.accountOf(deviceId);
    return { uploads: (await this.uploads.list(accountId, diagnosticAccountListLimit)).map(present) };
  }

  async remove(deviceId: string, diagnosticId: string) {
    const accountId = await this.accountOf(deviceId);
    if (!(await this.uploads.remove(accountId, diagnosticId))) throw notFound();
    await this.store.remove([diagnosticId]);
    this.logger.log(`[DiagnosticAccount] action=remove id=${diagnosticId} deviceId=${deviceId}`);
  }

  private async accountOf(deviceId: string) {
    const retryAfter = await this.limiter.hit('diagnostic_account', deviceId, diagnosticAccountRequestsPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '请求过于频繁', { retryAfter });
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    return accountId;
  }
}
