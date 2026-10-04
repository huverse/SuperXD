import { Inject, Injectable } from '@nestjs/common';
import Redis from 'ioredis';

import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys, RedisKeyTTL } from 'src/common/redis/redis_keys';

// 邀请是 5 分钟的短期运行态，只放 Redis：丢了只需对方重新出示二维码。
export abstract class InviteStore {
  // 登记新邀请并作废该设备之前的邀请。
  abstract create(ownerDeviceId: string, inviteId: string, publicKey: string): Promise<void>;
  // 只能作废自己的邀请；返回是否作废了。
  abstract revoke(ownerDeviceId: string, inviteId: string): Promise<boolean>;
  abstract find(inviteId: string): Promise<{ ownerDeviceId: string; publicKey: string } | null>;
}

// 新建：取旧邀请号 → 删旧邀请 → 写新邀请与归属，原子完成。KEYS 已带前缀，旧邀请 key 由 ARGV 传入的前缀拼出。
const createScript = `local previous = redis.call('GET', KEYS[2])
if previous then redis.call('DEL', ARGV[1] .. previous) end
redis.call('HSET', KEYS[1], 'ownerDeviceId', ARGV[2], 'publicKey', ARGV[3])
redis.call('EXPIRE', KEYS[1], ARGV[5])
redis.call('SET', KEYS[2], ARGV[4], 'EX', ARGV[5])
return 1`;

const revokeScript = `if redis.call('HGET', KEYS[1], 'ownerDeviceId') ~= ARGV[1] then return 0 end
redis.call('DEL', KEYS[1])
if redis.call('GET', KEYS[2]) == ARGV[2] then redis.call('DEL', KEYS[2]) end
return 1`;

@Injectable()
export class RedisInviteStore extends InviteStore {
  constructor(@Inject(REDIS) private readonly redis: Redis) {
    super();
  }

  async create(ownerDeviceId: string, inviteId: string, publicKey: string) {
    const invitePrefix = env().redis.keyPrefix + RedisKeys.invite('');
    await this.redis.eval(createScript, 2, RedisKeys.invite(inviteId), RedisKeys.inviteOwner(ownerDeviceId), invitePrefix, ownerDeviceId, publicKey, inviteId, RedisKeyTTL.invite);
  }

  async revoke(ownerDeviceId: string, inviteId: string) {
    return Number(await this.redis.eval(revokeScript, 2, RedisKeys.invite(inviteId), RedisKeys.inviteOwner(ownerDeviceId), ownerDeviceId, inviteId)) === 1;
  }

  async find(inviteId: string) {
    const row = await this.redis.hgetall(RedisKeys.invite(inviteId));
    return row.ownerDeviceId && row.publicKey ? { ownerDeviceId: row.ownerDeviceId, publicKey: row.publicKey } : null;
  }
}
