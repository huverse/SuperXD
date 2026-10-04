import { Global, Inject, Injectable, Logger, Module, OnApplicationShutdown } from '@nestjs/common';
import Redis from 'ioredis';

import { env } from 'src/config/env';
import { RedisKeys } from 'src/common/redis/redis_keys';

export const REDIS = Symbol('REDIS');

// 固定窗口计数：INCR 与首次设置过期在同一脚本内原子完成，返回本窗口内的累计次数。
const rateScript = `local count = redis.call('INCR', KEYS[1])
if count == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end
return count`;

// 只释放自己持有的锁：比对令牌后再删除，原子完成。
const unlockScript = `if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end
return 0`;

@Injectable()
export class RateLimiter {
  constructor(@Inject(REDIS) private readonly redis: Redis) {}

  // 返回 null 表示放行，否则返回需等待的秒数（到本窗口结束）。
  async hit(scope: string, subject: string, limit: number, windowSeconds: number): Promise<number | null> {
    const now = Math.floor(Date.now() / 1000);
    const window = Math.floor(now / windowSeconds);
    const count = Number(await this.redis.eval(rateScript, 1, RedisKeys.rate(scope, subject, window), windowSeconds));
    return count > limit ? (window + 1) * windowSeconds - now : null;
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
