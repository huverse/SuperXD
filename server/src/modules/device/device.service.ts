import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import Redis from 'ioredis';
import { KeyObject } from 'node:crypto';
import { LRUCache } from 'lru-cache';

import { RateLimiter, REDIS } from 'src/common/redis/redis.module';
import { RedisKeys, RedisKeyTTL } from 'src/common/redis/redis_keys';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { registerPerHour } from 'src/common/relay_limits';
import { decodeBase64url, deviceIdOf, ed25519Key } from 'src/common/crypto/relay_crypto';
import { DeviceRepository } from 'src/modules/device/device.repository';

@Injectable()
export class DeviceService {
  private readonly logger = new Logger('Device');
  // L1：设备号由签名公钥哈希而来，二者终身绑定，缓存不会过时；只需按条数淘汰。删除设备时同步移除。
  private readonly keys = new LRUCache<string, KeyObject>({ max: 50000 });

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
      const retryAfter = await this.limiter.hit('register', ip, registerPerHour, 3600);
      if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '注册过于频繁', { retryAfter });
    }
    const created = await this.devices.upsert(deviceId, signPublicKey, boxPublicKey);
    this.logger.log(`[Device] action=register deviceId=${deviceId} created=${created}`);
  }

  // 签名公钥：先查 L1，再查库；设备不存在返回 null。
  async signKey(deviceId: string): Promise<KeyObject | null> {
    const cached = this.keys.get(deviceId);
    if (cached) return cached;
    const device = await this.devices.find(deviceId);
    if (device === null) return null;
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
