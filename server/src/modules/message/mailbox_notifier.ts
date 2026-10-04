import { Inject, Injectable, Logger, OnApplicationShutdown, OnModuleInit } from '@nestjs/common';
import Redis from 'ioredis';

import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisChannels } from 'src/common/redis/redis_keys';
import { longPollPerDevice, longPollPerInstance } from 'src/common/relay_limits';

export type MailboxWaiter = { signal: Promise<void>; cancel: () => void };

// 长轮询的唤醒：投递消息后经 Redis 发布订阅广播收件设备号，各实例只唤醒自己内存里挂着的请求。
// 广播量随消息量与实例数增长，单条只有一个设备号，不随在线人数增长；通知丢了也只是等到超时再取，不丢消息。
@Injectable()
export class MailboxNotifier implements OnModuleInit, OnApplicationShutdown {
  private readonly logger = new Logger('MailboxNotifier');
  private readonly channel = RedisChannels.mailNotify(env().redis.keyPrefix);
  // 设备号 → 挂起的唤醒函数（按挂起先后），条目数受 longPollPerInstance 约束。
  private readonly waiters = new Map<string, Array<() => void>>();
  private total = 0;
  private subscriber?: Redis;

  constructor(@Inject(REDIS) private readonly redis: Redis) {}

  async onModuleInit() {
    // 订阅模式的连接不能再发普通命令，单独复制一条。
    this.subscriber = this.redis.duplicate();
    this.subscriber.on('message', (_channel, deviceId) => this.wake(deviceId));
    await this.subscriber.subscribe(this.channel);
  }

  async onApplicationShutdown() {
    for (const deviceId of [...this.waiters.keys()]) this.wake(deviceId);
    await this.subscriber?.quit();
  }

  get size() {
    return this.total;
  }

  // 投递路径调用，不等待：通知失败只记日志，收件方最多等到长轮询超时再取到。
  notify(deviceId: string) {
    this.redis.publish(this.channel, deviceId).catch((error) => {
      console.error(error);
      this.logger.error('[MailboxNotifier] action=publish errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    });
  }

  // 登记一个等待；超出实例上限返回 null（调用方立即返回空）。同一设备挂起超过上限时让最早的先返回。
  wait(deviceId: string, timeoutMs: number): MailboxWaiter | null {
    if (this.total >= longPollPerInstance) return null;
    const list = this.waiters.get(deviceId) ?? [];
    if (list.length >= longPollPerDevice) list[0]();
    let release!: () => void;
    let timer: NodeJS.Timeout | undefined;
    const signal = new Promise<void>((resolve) => {
      release = () => {
        if (timer === undefined) return;
        clearTimeout(timer);
        timer = undefined;
        this.remove(deviceId, release);
        resolve();
      };
    });
    timer = setTimeout(release, timeoutMs);
    const current = this.waiters.get(deviceId) ?? [];
    current.push(release);
    this.waiters.set(deviceId, current);
    this.total++;
    return { signal, cancel: release };
  }

  private wake(deviceId: string) {
    for (const release of [...(this.waiters.get(deviceId) ?? [])]) release();
  }

  private remove(deviceId: string, release: () => void) {
    const list = this.waiters.get(deviceId);
    if (!list) return;
    const index = list.indexOf(release);
    if (index < 0) return;
    list.splice(index, 1);
    this.total--;
    if (list.length === 0) this.waiters.delete(deviceId);
  }
}
