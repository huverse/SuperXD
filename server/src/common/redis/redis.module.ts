import { Global, Inject, Injectable, Logger, Module, OnApplicationShutdown } from '@nestjs/common';
import Redis from 'ioredis';

import { env } from 'src/config/env';
import { RedisKeys } from 'src/common/redis/redis_keys';

export const REDIS = Symbol('REDIS');

// 固定窗口计数：同一主体的几个窗口按顺序 INCR（首次设置过期），在同一脚本内原子完成、一次往返。ARGV 依次是每个窗口的上限与秒数。
// 遇到第一个超限的窗口就停下并返回它的序号（从 1 起），后面的窗口不计这次被拒的请求，与逐个检查的效果一致；全部放行返回 0。
const rateScript = `for index, key in ipairs(KEYS) do
  local count = redis.call('INCR', key)
  if count == 1 then redis.call('EXPIRE', key, ARGV[index * 2]) end
  if count > tonumber(ARGV[index * 2 - 1]) then return index end
end
return 0`;

export type RateRule = { scope: string; limit: number; windowSeconds: number };

// 只释放自己持有的锁：比对令牌后再删除，原子完成。
const unlockScript = `if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end
return 0`;

@Injectable()
export class RateLimiter {
  constructor(@Inject(REDIS) private readonly redis: Redis) {}

  // 返回 null 表示放行，否则返回需等待的秒数（到本窗口结束）。
  hit(scope: string, subject: string, limit: number, windowSeconds: number): Promise<number | null> {
    return this.hitAll(subject, [{ scope, limit, windowSeconds }]);
  }

  // 同一主体的几个窗口一次往返按顺序检查：返回 null 表示全部放行，否则返回第一个超限窗口需等待的秒数。
  async hitAll(subject: string, rules: RateRule[]): Promise<number | null> {
    const now = Math.floor(Date.now() / 1000);
    const windows = rules.map((rule) => Math.floor(now / rule.windowSeconds));
    const keys = rules.map((rule, index) => RedisKeys.rate(rule.scope, subject, windows[index]));
    const exceeded = Number(await this.redis.eval(rateScript, keys.length, ...keys, ...rules.flatMap((rule) => [rule.limit, rule.windowSeconds])));
    return exceeded === 0 ? null : (windows[exceeded - 1] + 1) * rules[exceeded - 1].windowSeconds - now;
  }
}

@Injectable()
export class DistributedLock {
  constructor(@Inject(REDIS) private readonly redis: Redis) {}

  // 抢不到返回 false，不等待；多实例同一任务全局只执行一次。
  async run(name: string, ttlSeconds: number, task: () => Promise<void>): Promise<boolean> {
    const token = `${process.pid}:${Date.now()}:${Math.random()}`;
    const acquired = await this.redis.set(RedisKeys.lock(name), token, 'EX', ttlSeconds, 'NX');
    if (acquired !== 'OK') return false;
    try {
      await task();
    } finally {
      await this.redis.eval(unlockScript, 1, RedisKeys.lock(name), token);
    }
    return true;
  }
}

@Injectable()
class RedisCloser implements OnApplicationShutdown {
  constructor(@Inject(REDIS) private readonly redis: Redis) {}
  async onApplicationShutdown() {
    await this.redis.quit();
  }
}

@Global()
@Module({
  providers: [
    {
      provide: REDIS,
      useFactory: () => {
        const config = env().redis;
        // 命令超时 3 秒：Redis 卡住时请求快速失败，不拖住连接。
        const client = new Redis({ host: config.host, port: config.port, password: config.password, db: config.db, keyPrefix: config.keyPrefix, commandTimeout: 3000, connectTimeout: 5000, maxRetriesPerRequest: 1 });
        client.on('error', (error) => {
          console.error(error);
          new Logger('Redis').error('[Redis] action=connection errorType=' + error.constructor.name);
        });
        return client;
      },
    },
    RateLimiter,
    DistributedLock,
    RedisCloser,
  ],
  exports: [REDIS, RateLimiter, DistributedLock],
})
export class RedisModule {}
