import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { createHash, randomBytes } from 'node:crypto';

import { rateSubjectOf } from 'src/common/client_ip';
import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { chaoxingPackMaxBytes, chaoxingPackPerHour, chaoxingPackPickupPerHour, chaoxingPackRevokePerHour, chaoxingPackTtlSeconds } from 'src/common/relay_limits';
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

  async submit(ip: string, data: string): Promise<{ id: string; expiresAt: number; revokeToken: string }> {
    const retryAfter = await this.limiter.hit('chaoxing_pack', rateSubjectOf(ip), chaoxingPackPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '提交过于频繁', { retryAfter });
    const bytes = decodeBase64url(data);
    if (bytes === null || bytes.length === 0) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '凭据包格式不正确');
    if (bytes.length > chaoxingPackMaxBytes) throw new RelayError(RelayCode.envelopeTooLarge, HttpStatus.PAYLOAD_TOO_LARGE, '内容过大');
    const pickupId = randomBytes(12).toString('base64url');
    const revokeToken = randomBytes(16).toString('base64url');
    const expireTime = new Date(Date.now() + chaoxingPackTtlSeconds * 1000);
    await this.packs.insert(pickupId, bytes, expireTime, hashOf(revokeToken));
    this.logger.debug(`[ChaoxingPack] action=submit bytes=${bytes.length}`);
    return { id: pickupId, expiresAt: expireTime.getTime(), revokeToken };
  }

  // [人工决策-2026-10-08 20:01:58] 代签码轮换即作废：出示方重新生成、改附带的人脸照片或离开出示页时，作废上一张码（同付款码、登录二维码刷新）。
  // 凭投递时拿到的口令作废，别人拿到取件号也作废不了；口令不对、已取走或已过期都按成功处理，不透露包是否存在。
  async revoke(ip: string, pickupId: string, token: string): Promise<void> {
    const retryAfter = await this.limiter.hit('chaoxing_pack_revoke', rateSubjectOf(ip), chaoxingPackRevokePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '作废过于频繁', { retryAfter });
    const revoked = await this.packs.revoke(pickupId, hashOf(token));
    this.logger.debug(`[ChaoxingPack] action=revoke revoked=${revoked}`);
  }

  // 取走即删：同一个人重复取只会成功一次，别人拿了取件号也来不及再用。
  async pickup(ip: string, pickupId: string): Promise<{ data: string }> {
    const retryAfter = await this.limiter.hit('chaoxing_pack_pickup', rateSubjectOf(ip), chaoxingPackPickupPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '取件过于频繁', { retryAfter });
    const bytes = await this.packs.take(pickupId, new Date());
    if (bytes === null) throw new RelayError(RelayCode.packNotFound, HttpStatus.NOT_FOUND, '凭据包不存在、已被取走或已过期');
    this.logger.debug(`[ChaoxingPack] action=pickup bytes=${bytes.length}`);
    return { data: bytes.toString('base64url') };
  }
}

const hashOf = (token: string) => createHash('sha256').update(token).digest('hex');
