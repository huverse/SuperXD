import { createHash, randomBytes } from 'node:crypto';
import type { IncomingMessage } from 'node:http';
import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import Redis from 'ioredis';

import { rateSubjectOf } from 'src/common/client_ip';
import { REDIS, RateLimiter } from 'src/common/redis/redis.module';
import { RedisKeys, RedisKeyTTL } from 'src/common/redis/redis_keys';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { diagnosticKeepDays, diagnosticUploadMinBytes, diagnosticUploadPerHour } from 'src/common/relay_limits';
import { DiagnosticStore, newDiagnosticId } from 'src/modules/diagnostic/diagnostic.store';
import * as dtos from 'src/modules/diagnostic/diagnostic.dto';

// 诊断包（人工决策见客户端 lib/domain/diagnostic_upload.dart）：哑信箱，只收用户确认后上传、已在本机用开发者公钥加密的日志包，
// 服务端没有解密用的密钥，也不提供下载（开发者经 ssh 从目录里取）；免签名（没开私信的人也要能传），按来源 IP 限流。
// 回执另给一个一次性的认领口令（只存它的 sha256，一天过期）：登录了应用账号的客户端紧接着凭它把包认领到账号下（diagnostic_account.service.ts）。
export const claimHash = (claim: string) => createHash('sha256').update(claim).digest('hex');

@Injectable()
export class DiagnosticService {
  private readonly logger = new Logger('Diagnostic');

  constructor(
    private readonly limiter: RateLimiter,
    private readonly store: DiagnosticStore,
    @Inject(REDIS) private readonly redis: Redis,
  ) {}

  // length 是请求头声明的长度（超限、分块上传与非二进制的请求体在解析前已被 diagnostic_body_limit.ts 挡掉）；body 是还没读的请求流。
  async upload(ip: string, length: number, body: IncomingMessage): Promise<dtos.DiagnosticReceiptDto> {
    if (!Number.isInteger(length) || length < diagnosticUploadMinBytes) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '诊断包为空或不完整');
    const retryAfter = await this.limiter.hit('diagnostic_upload', rateSubjectOf(ip), diagnosticUploadPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '诊断包上传过于频繁', { retryAfter });
    if (!(await this.store.reserve(length))) {
      this.logger.warn(`[Diagnostic] action=upload errorType=StoreFull bytes=${length}`);
      throw new RelayError(RelayCode.mailboxFull, HttpStatus.SERVICE_UNAVAILABLE, '诊断包存满了');
    }
    const id = newDiagnosticId();
    try {
      await this.store.save(id, body);
    } catch (error) {
      await this.store.release(length);
      // 客户端中途断开（换网、看门狗中止）不是服务端的错，回什么也送不到，只记一行；写盘出错（目录不可写、磁盘满）照常带堆栈上抛。
      const code = (error as NodeJS.ErrnoException).code;
      if (code === 'ECONNRESET' || code === 'ERR_STREAM_PREMATURE_CLOSE') {
        this.logger.warn(`[Diagnostic] action=upload errorType=Aborted bytes=${length}`);
        throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '上传中断');
      }
      throw error;
    }
    const claim = randomBytes(16).toString('base64url');
    await this.redis.set(RedisKeys.diagnosticClaim(id), claimHash(claim), 'EX', RedisKeyTTL.diagnosticClaim);
    this.logger.log(`[Diagnostic] action=upload id=${id} bytes=${length}`);
    return { id, keepDays: diagnosticKeepDays, claim };
  }
}
