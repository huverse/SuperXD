import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { randomBytes } from 'node:crypto';

import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { chaoxingPackMaxBytes, chaoxingPackPerHour, chaoxingPackPickupPerHour, chaoxingPackTtlSeconds } from 'src/common/relay_limits';
import { decodeBase64url } from 'src/common/crypto/relay_crypto';
import { ChaoxingPackRepository } from 'src/modules/chaoxing/chaoxing_pack.repository';

// 代签凭据的临时信箱。
// [人工决策-2026-10-06 21:47:28] 面对面代签用「取件号 + 一次性密钥」：二维码里只有取件号与密钥，密文放这里取走即删，
// 所以这个接口不做设备签名（拿到取件号的人就是收件人，一对一、一次性、10 分钟过期），靠取件号随机性与按 IP 限流防滥用。
@Injectable()
export class ChaoxingPackService {
  private readonly logger = new Logger('ChaoxingPack');

  constructor(
    private readonly packs: ChaoxingPackRepository,
    private readonly limiter: RateLimiter,
  ) {}

  async submit(ip: string, data: string): Promise<{ id: string; expiresAt: number }> {
    const retryAfter = await this.limiter.hit('chaoxing_pack', ip, chaoxingPackPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '提交过于频繁', { retryAfter });
    const bytes = decodeBase64url(data);
    if (bytes === null || bytes.length === 0) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '凭据包格式不正确');
    if (bytes.length > chaoxingPackMaxBytes) throw new RelayError(RelayCode.envelopeTooLarge, HttpStatus.PAYLOAD_TOO_LARGE, '内容过大');
    const pickupId = randomBytes(12).toString('base64url');
    const expireTime = new Date(Date.now() + chaoxingPackTtlSeconds * 1000);
    await this.packs.insert(pickupId, bytes, expireTime);
    this.logger.debug(`[ChaoxingPack] action=submit ip=${ip} bytes=${bytes.length}`);
    return { id: pickupId, expiresAt: expireTime.getTime() };
  }

  // 取走即删：同一个人重复取只会成功一次，别人拿了取件号也来不及再用。
  async pickup(ip: string, pickupId: string): Promise<{ data: string }> {
    const retryAfter = await this.limiter.hit('chaoxing_pack_pickup', ip, chaoxingPackPickupPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '取件过于频繁', { retryAfter });
    const bytes = await this.packs.take(pickupId, new Date());
    if (bytes === null) throw new RelayError(RelayCode.packNotFound, HttpStatus.NOT_FOUND, '凭据包不存在、已被取走或已过期');
    this.logger.debug(`[ChaoxingPack] action=pickup ip=${ip} bytes=${bytes.length}`);
    return { data: bytes.toString('base64url') };
  }
}
