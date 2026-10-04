import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, In, LessThan, Repository } from 'typeorm';

import { DeviceEntity } from 'src/modules/device/device.entity';

// 设备存储端口：服务只依赖这个抽象，实现可替换。
export abstract class DeviceRepository {
  abstract find(deviceId: string): Promise<DeviceEntity | null>;
  // 按设备号顺序加行锁（FOR UPDATE），返回存在的设备号；须在调用方事务内执行。
  abstract lock(deviceIds: string[], manager: EntityManager): Promise<string[]>;
  // 不存在则插入、存在则更新加密公钥；返回是否新建。
  abstract upsert(deviceId: string, signPublicKey: string, boxPublicKey: string): Promise<boolean>;
  abstract touch(deviceId: string): Promise<void>;
  // 取最多 limit 台最后活跃早于 before 的设备号，走 idx_last_seen。
  abstract idle(before: Date, limit: number): Promise<string[]>;
  abstract remove(deviceIds: string[], manager: EntityManager): Promise<void>;
}

@Injectable()
export class TypeormDeviceRepository extends DeviceRepository {
  constructor(@InjectRepository(DeviceEntity) private readonly repository: Repository<DeviceEntity>) {
    super();
  }

  find(deviceId: string) {
    return this.repository.findOne({ where: { deviceId } });
  }

  async lock(deviceIds: string[], manager: EntityManager) {
    const rows = await manager.getRepository(DeviceEntity).find({ select: { id: true, deviceId: true }, where: { deviceId: In(deviceIds) }, order: { deviceId: 'ASC' }, lock: { mode: 'pessimistic_write' } });
    return rows.map((row) => row.deviceId);
  }

  async upsert(deviceId: string, signPublicKey: string, boxPublicKey: string) {
    const now = new Date();
    // 唯一键冲突时只更新加密公钥与时间，签名公钥由设备号决定、不会变。
    const result = await this.repository.query(
      'INSERT INTO device (device_id, sign_public_key, box_public_key, last_seen_time, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?) ' +
        'ON DUPLICATE KEY UPDATE box_public_key = VALUES(box_public_key), last_seen_time = VALUES(last_seen_time), update_time = VALUES(update_time)',
      [deviceId, signPublicKey, boxPublicKey, now, now, now],
    );
    // MySQL：新插入 affectedRows=1，更新为 2，值未变为 0。
    return (result as { affectedRows: number }).affectedRows === 1;
  }

  async touch(deviceId: string) {
    const now = new Date();
    await this.repository.update({ deviceId }, { lastSeenTime: now, updateTime: now });
  }

  async idle(before: Date, limit: number) {
    const rows = await this.repository.find({ select: { deviceId: true }, where: { lastSeenTime: LessThan(before) }, order: { lastSeenTime: 'ASC' }, take: limit });
    return rows.map((row) => row.deviceId);
  }

  async remove(deviceIds: string[], manager: EntityManager) {
    if (deviceIds.length > 0) await manager.getRepository(DeviceEntity).delete({ deviceId: In(deviceIds) });
  }
}
