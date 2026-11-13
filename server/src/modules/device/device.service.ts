import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import Redis from 'ioredis';
import { KeyObject } from 'node:crypto';
import { LRUCache } from 'lru-cache';

import { rateSubjectOf } from 'src/common/client_ip';
import { RateLimiter, REDIS } from 'src/common/redis/redis.module';
import { RedisKeys, RedisKeyTTL } from 'src/common/redis/redis_keys';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { deviceKeyCacheSeconds, registerPerHour } from 'src/common/relay_limits';
import { decodeBase64url, deviceIdOf, ed25519Key } from 'src/common/crypto/relay_crypto';
import { DeviceRepository } from 'src/modules/device/device.repository';

// 设备号负缓存的两种值（键见 RedisKeys.deviceMissing）。
const missingMark = 'missing';
const registeredMark = 'registered';

@Injectable()
export class DeviceService {
  private readonly logger = new Logger('Device');
  // L1：设备号由签名公钥哈希而来，二者终身绑定，缓存不会过时；按条数淘汰，另带 TTL（多实例下别的实例删了设备，这里最迟 TTL 后不再认）。
  // 本实例删除设备时同步移除。
  private readonly keys = new LRUCache<string, KeyObject>({ max: 50000, ttl: deviceKeyCacheSeconds * 1000 });

  constructor(
    private readonly devices: DeviceRepository,
    private readonly limiter: RateLimiter,
    @Inject(REDIS) private readonly redis: Redis,
  ) {}

  async register(deviceId: string, signPublicKey: string, boxPublicKey: string, ip: string) {
    const sign = decodeBase64url(signPublicKey, 32), box = decodeBase64url(boxPublicKey, 32);
    if (sign === null || box === null) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '公钥格式不正确');
    if (deviceIdOf(sign) !== deviceId) throw new RelayError(RelayCode.deviceMismatch, HttpStatus.BAD_REQUEST, '设备号与公钥不符');
    // 已注册的设备重复注册（重装前的同一密钥、换加密公钥）不计入限流。
    if ((await this.devices.find(deviceId)) === null) {
      const retryAfter = await this.limiter.hit('register', rateSubjectOf(ip), registerPerHour, 3600);
      if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '注册过于频繁', { retryAfter });
    }
    await this.enroll(deviceId, signPublicKey, boxPublicKey);
  }

  // 登记设备、不过注册限流：给已经另有限流把关的入口用（应用账号登录核对通过后登记它的设备密钥）。调用方已核对设备号与公钥一致（自签名）。
  async enroll(deviceId: string, signPublicKey: string, boxPublicKey: string) {
    const created = await this.devices.upsert(deviceId, signPublicKey, boxPublicKey);
    // 覆盖负缓存：新注册立刻在所有实例生效；这个标记留到负缓存期满，期间与注册交错、查库没查到的请求也写不回「不存在」（signKey 用 NX）。
    await this.redis.set(RedisKeys.deviceMissing(deviceId), registeredMark, 'EX', RedisKeyTTL.deviceMissing);
    this.logger.log(`[Device] action=register deviceId=${deviceId} created=${created}`);
  }

  // 签名公钥：先查 L1，再看负缓存，最后查库；设备不存在返回 null。
  // [人工决策-2026-11-10 13:05:26] 未注册设备号的反复请求不再每次查库（用户 11-10 确认加固方向，「负缓存」与「按来源 IP 的失败鉴权限流」二选一交由实现权衡）：
  // 选了 Redis 负缓存——查库没有的设备号记 60 秒，期间同一设备号直接拒绝；注册时改记 registered，新注册立刻在所有实例生效，查库与注册交错也不会误记。
  // 没选按 IP 失败限流：校园网 NAT 共用出口，服务端丢了设备的客户端（如从旧备份恢复后）会按最长 60 秒退避一直重试，同一出口几十台就会触发，
  // 连带挡住同出口里公钥不在 L1 的正常设备。负缓存挡不住每次换随机设备号的刷库（每个新号仍查一次唯一索引），那种整体流量要在前置代理或安全组按 IP 限速。
  async signKey(deviceId: string): Promise<KeyObject | null> {
    const cached = this.keys.get(deviceId);
    if (cached) return cached;
    if ((await this.redis.get(RedisKeys.deviceMissing(deviceId))) === missingMark) return null;
    const device = await this.devices.find(deviceId);
    if (device === null) {
      // NX：刚注册留下的 registered 还在时不覆盖。拒绝路径不等这次写入。
      this.redis.set(RedisKeys.deviceMissing(deviceId), missingMark, 'EX', RedisKeyTTL.deviceMissing, 'NX').catch((error) => console.error(error));
      return null;
    }
    const key = ed25519Key(decodeBase64url(device.signPublicKey, 32)!);
    this.keys.set(deviceId, key);
    return key;
  }

  forget(deviceIds: string[]) {
    for (const deviceId of deviceIds) this.keys.delete(deviceId);
  }

  // 最后活跃时间每设备每小时最多写一次库；热路径调用方不等待。
  async touch(deviceId: string) {
    const first = await this.redis.set(RedisKeys.seen(deviceId), '1', 'EX', RedisKeyTTL.seen, 'NX');
    if (first === 'OK') await this.devices.touch(deviceId);
  }
}
