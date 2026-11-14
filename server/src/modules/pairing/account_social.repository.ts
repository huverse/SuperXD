import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';

import { AccountSocialEntity } from 'src/modules/pairing/account_social.entity';

// 应用账号的私信设备登记的存储端口：服务只依赖这个抽象。
export abstract class AccountSocialRepository {
  // 锁住这个账号的那一行（FOR UPDATE，没有就锁住间隙），返回现在的私信设备号；须在调用方事务内执行。
  abstract lockOf(accountId: string, manager: EntityManager): Promise<string | null>;
  // 这台私信设备挂在哪个账号下。
  abstract ownerOf(deviceId: string, manager: EntityManager): Promise<string | null>;
  // 把账号的私信设备设为 deviceId（没有就插入）；须在调用方事务内执行。
  abstract set(accountId: string, deviceId: string, manager: EntityManager): Promise<void>;
  // 删设备时一并删登记；须在调用方事务内执行。
  abstract unlinkDevices(deviceIds: string[], manager: EntityManager): Promise<void>;
  // 注销账号：删登记，返回这些账号的私信设备号（调用方连同设备一起删）；须在调用方事务内执行。
  abstract deleteAccounts(accountIds: string[], manager: EntityManager): Promise<string[]>;
}

@Injectable()
export class TypeormAccountSocialRepository extends AccountSocialRepository {
  constructor(@InjectRepository(AccountSocialEntity) private readonly rows: Repository<AccountSocialEntity>) {
    super();
  }

  async lockOf(accountId: string, manager: EntityManager) {
    const rows = (await manager.query('SELECT device_id AS deviceId FROM account_social WHERE account_id = ? FOR UPDATE', [accountId])) as { deviceId: string }[];
    return rows[0]?.deviceId ?? null;
  }

  async ownerOf(deviceId: string, manager: EntityManager) {
    const rows = (await manager.query('SELECT account_id AS accountId FROM account_social WHERE device_id = ?', [deviceId])) as { accountId: string }[];
    return rows[0]?.accountId ?? null;
  }

  async set(accountId: string, deviceId: string, manager: EntityManager) {
    const now = new Date();
    await manager.query(
      'INSERT INTO account_social (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE device_id = VALUES(device_id), update_time = VALUES(update_time)',
      [accountId, deviceId, now, now],
    );
  }

  async unlinkDevices(deviceIds: string[], manager: EntityManager) {
    if (deviceIds.length > 0) await manager.query('DELETE FROM account_social WHERE device_id IN (?)', [deviceIds]);
  }

  async deleteAccounts(accountIds: string[], manager: EntityManager) {
    if (accountIds.length === 0) return [];
    const rows = (await manager.query('SELECT device_id AS deviceId FROM account_social WHERE account_id IN (?) FOR UPDATE', [accountIds])) as { deviceId: string }[];
    await manager.query('DELETE FROM account_social WHERE account_id IN (?)', [accountIds]);
    return rows.map((row) => row.deviceId);
  }
}
