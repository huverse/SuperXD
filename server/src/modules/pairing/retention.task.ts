import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { DataSource } from 'typeorm';

import { DistributedLock } from 'src/common/redis/redis.module';
import { cleanupBatch, deviceIdleDays } from 'src/common/relay_limits';
import { DeviceRepository } from 'src/modules/device/device.repository';
import { DeviceService } from 'src/modules/device/device.service';
import { FriendshipRepository } from 'src/modules/friend/friendship.repository';
import { MessageRepository } from 'src/modules/message/message.repository';

// 数据保留：过期消息与长期不活跃的设备分批删除。多实例抢分布式锁，全局只跑一份；每批 1000 行，单次运行工作量有界。
@Injectable()
export class RetentionTask {
  private readonly logger = new Logger('Retention');

  constructor(
    private readonly dataSource: DataSource,
    private readonly lock: DistributedLock,
    private readonly devices: DeviceRepository,
    private readonly deviceService: DeviceService,
    private readonly friendships: FriendshipRepository,
    private readonly messages: MessageRepository,
  ) {}

  // 每 10 分钟一次，与业务时区无关（只比较 UTC 绝对时刻），显式按 UTC 调度。
  @Cron('0 */10 * * * *', { timeZone: 'UTC' })
  async run() {
    try {
      await this.lock.run('retention', 9 * 60, () => this.sweep());
    } catch (error) {
      console.error(error);
      this.logger.error('[Retention] action=run errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
    }
  }

  // 每轮最多 20 批，避免积压时单次运行过长；剩下的下一轮继续。
  async sweep() {
    const now = new Date();
    let expired = 0;
    for (let round = 0; round < 20; round++) {
      const removed = await this.messages.deleteExpired(now, cleanupBatch);
      expired += removed;
      if (removed < cleanupBatch) break;
    }
    const idleBefore = new Date(now.getTime() - deviceIdleDays * 24 * 3600 * 1000);
    let idle = 0;
    for (let round = 0; round < 20; round++) {
      const deviceIds = await this.devices.idle(idleBefore, cleanupBatch);
      if (deviceIds.length === 0) break;
      await this.dataSource.transaction(async (manager) => {
        await this.friendships.removeAllOf(deviceIds, manager);
        await this.messages.removeMailboxes(deviceIds, manager);
        await this.devices.remove(deviceIds, manager);
      });
      this.deviceService.forget(deviceIds);
      idle += deviceIds.length;
      if (deviceIds.length < cleanupBatch) break;
    }
    this.logger.log(`[Retention] action=sweep expiredMessages=${expired} idleDevices=${idle}`);
  }
}
