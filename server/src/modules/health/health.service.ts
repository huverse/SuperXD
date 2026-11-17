import { Inject, Injectable, Logger } from '@nestjs/common';
import Redis from 'ioredis';
import { DataSource } from 'typeorm';

import { env } from 'src/config/env';
import { ErrorMonitor } from 'src/common/error_monitor';
import { REDIS } from 'src/common/redis/redis.module';
import { readinessTimeoutMs } from 'src/common/relay_limits';

export type DependencyState = 'ok' | 'timeout' | 'down';
export type Readiness = { ready: boolean; mysql: DependencyState; redis: DependencyState; alerts: number; version: string };

// 一项检查：限时内成功为 ok，超时为 timeout，出错为 down。检查本身迟到的失败也接住（不留未处理的拒绝）。
const probe = async (check: () => Promise<unknown>): Promise<{ state: DependencyState; error?: unknown }> => {
  let timer: NodeJS.Timeout | undefined;
  const attempt = check().then(
    () => ({ state: 'ok' as const }),
    (error: unknown) => ({ state: 'down' as const, error }),
  );
  const timeout = new Promise<{ state: 'timeout' }>((resolve) => {
    timer = setTimeout(() => resolve({ state: 'timeout' }), readinessTimeoutMs);
  });
  try {
    return await Promise.race([attempt, timeout]);
  } finally {
    clearTimeout(timer);
  }
};

// 就绪探测（人工决策见 src/common/error_monitor.ts）：用服务自己的连接池与 Redis 连接各做一次最轻的查询，能用才算就绪；
// 容器健康检查与外部探活都请求它。状态变了才记日志（不就绪时带堆栈），健康检查每 30 秒一次，出故障时不刷屏。
@Injectable()
export class HealthService {
  private readonly logger = new Logger('Health');
  private wasReady = true;

  constructor(
    private readonly dataSource: DataSource,
    @Inject(REDIS) private readonly redis: Redis,
    private readonly monitor: ErrorMonitor,
  ) {}

  async ready(): Promise<Readiness> {
    const [mysql, redis] = await Promise.all([probe(() => this.dataSource.query('SELECT 1')), probe(() => this.redis.ping())]);
    const ready = mysql.state === 'ok' && redis.state === 'ok';
    if (ready !== this.wasReady) {
      this.wasReady = ready;
      for (const failed of [mysql.error, redis.error]) if (failed !== undefined) console.error(failed);
      this.logger.warn(`[Health] action=ready ready=${ready} mysql=${mysql.state} redis=${redis.state}`);
    }
    return { ready, mysql: mysql.state, redis: redis.state, alerts: this.monitor.alerting, version: env().buildVersion };
  }
}
