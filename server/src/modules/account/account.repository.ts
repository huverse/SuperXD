import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { randomBytes } from 'node:crypto';
import { EntityManager, Repository } from 'typeorm';

import { accountDeviceLimit, deviceRemovalChunk } from 'src/common/relay_limits';
import { AppAccountEntity } from 'src/modules/account/account.entity';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';

export type AccountSummary = { accountId: string; username: string; deviceCount: number; createTime: Date };
export type AccountCredentials = { accountId: string; passwordHash: string; recoveryHash: string };

// 账号存储端口：服务只依赖这个抽象。用户名一律是规范写法（小写），唯一。
export abstract class AccountRepository {
  // 注册：用户名没被占用就新建账号并登记这把设备密钥（一把密钥只属于一个账号，原来属于别的账号就改过来）；被占用返回 null。同一事务。
  abstract register(username: string, passwordHash: string, recoveryHash: string, deviceId: string, now: Date): Promise<string | null>;
  // 这个用户名的账号号与两个哈希（登录、用恢复码重设时核对）；没有返回 null。
  abstract credentialsOf(username: string): Promise<AccountCredentials | null>;
  // 改密码或恢复码的哈希（不给的不改）；账号不在了返回 false。
  abstract updateSecrets(accountId: string, secrets: { passwordHash?: string; recoveryHash?: string }, now: Date): Promise<boolean>;
  // 把一把设备密钥登记到已有账号下（登录、扫码登录；原来属于别的账号就改过来，超过上限删最久没用的），顺带记最后活跃。账号不在了返回 false。
  // only 为真时（凭恢复码重设）同一事务里删掉账号下别的密钥登记，只留这一把。
  abstract link(accountId: string, deviceId: string, now: Date, only?: boolean): Promise<boolean>;
  // 这把密钥所在账号的建立时刻；没登录返回 null。
  abstract createdOf(deviceId: string): Promise<Date | null>;
  // 这把密钥所在的账号，顺带记最后活跃；没登录返回 null。
  abstract summaryOf(deviceId: string, now: Date): Promise<AccountSummary | null>;
  // 这把密钥所在的账号号（积分、挑战、节日抽奖按它认人），只读不记活跃；没登录返回 null。
  abstract accountOf(deviceId: string): Promise<string | null>;
  // 注销这把密钥所在的账号：全部密钥的登记、挂在账号下的数据与账号本身，同一事务里给这些密钥记墓碑。没登录返回 false。
  abstract deleteOf(deviceId: string): Promise<boolean>;
  // 这把密钥是不是属于一个已注销的账号（墓碑还在保留期内）；只在没登录的路径上查。
  abstract deletedOf(deviceId: string): Promise<boolean>;
  // 这把密钥有别的签名请求（设备模块每台每小时通知一次）：它所在的账号记最后活跃，没登录什么也不做。
  abstract touchOf(deviceId: string, now: Date): Promise<void>;
  // 删最多 limit 条记于 before 之前的墓碑，返回删掉的条数。
  abstract deleteTombstones(before: Date, limit: number): Promise<number>;
  // 删设备时连带删登记，须在调用方事务内（跨领域的设备删除由 pairing 编排）。
  abstract unlinkDevices(deviceIds: string[], manager: EntityManager): Promise<void>;
  // 删最多 limit 个最后活跃早于 before 的账号（连同密钥登记），返回删掉的个数。
  abstract deleteIdle(before: Date, limit: number): Promise<number>;
}

@Injectable()
export class TypeormAccountRepository extends AccountRepository {
  constructor(
    @InjectRepository(AppAccountEntity) private readonly accounts: Repository<AppAccountEntity>,
    private readonly hooks: AccountDataHooks,
  ) {
    super();
  }

  register(username: string, passwordHash: string, recoveryHash: string, deviceId: string, now: Date) {
    return this.accounts.manager.transaction(async (manager) => {
      const accountId = randomBytes(16).toString('base64url');
      // 唯一键 uk_username：并发注册同一个用户名只有一个插得进去。
      const inserted = (await manager.query(
        'INSERT IGNORE INTO app_account (account_id, username, password_hash, recovery_hash, last_seen_time, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [accountId, username, passwordHash, recoveryHash, now, now, now],
      )) as { affectedRows: number };
      if (inserted.affectedRows !== 1) return null;
      await this.linkIn(manager, accountId, deviceId, now);
      return accountId;
    });
  }

  async credentialsOf(username: string) {
    const rows = (await this.accounts.query('SELECT account_id AS accountId, password_hash AS passwordHash, recovery_hash AS recoveryHash FROM app_account WHERE username = ?', [username])) as AccountCredentials[];
    return rows[0] ?? null;
  }

  async updateSecrets(accountId: string, secrets: { passwordHash?: string; recoveryHash?: string }, now: Date) {
    const updated = await this.accounts.update({ accountId }, { ...secrets, updateTime: now });
    return updated.affected === 1;
  }

  link(accountId: string, deviceId: string, now: Date, only = false) {
    return this.accounts.manager.transaction(async (manager) => {
      const updated = (await manager.query('UPDATE app_account SET last_seen_time = ?, update_time = ? WHERE account_id = ?', [now, now, accountId])) as { affectedRows: number };
      if (updated.affectedRows !== 1) return false;
      await this.linkIn(manager, accountId, deviceId, now);
      // 一个账号最多 accountDeviceLimit 条登记，走 idx_account。
      if (only) {
        await manager.query('DELETE FROM account_device WHERE account_id = ? AND device_id <> ?', [accountId, deviceId]);
        // 私信一起收回（人工决策见 account.service.ts 类上方 11-15 21:48 那条）：由私信模块登记的收回钩子停掉这个账号的私信设备。
        await this.hooks.revoke(manager, [accountId]);
      }
      return true;
    });
  }

  async createdOf(deviceId: string) {
    const rows = (await this.accounts.query('SELECT a.create_time AS createTime FROM account_device d JOIN app_account a ON a.account_id = d.account_id WHERE d.device_id = ? LIMIT 1', [deviceId])) as { createTime: Date }[];
    return rows[0]?.createTime ?? null;
  }

  // 登记设备密钥（一把只属于一个账号）并把账号下的密钥压到上限以内，须在调用方事务内。登记上了就不再是已注销账号的密钥（墓碑删掉）。
  private async linkIn(manager: EntityManager, accountId: string, deviceId: string, now: Date) {
    await manager.query('DELETE FROM account_tombstone WHERE device_id = ?', [deviceId]);
    await manager.query(
      'INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE account_id = VALUES(account_id), update_time = VALUES(update_time)',
      [accountId, deviceId, now, now],
    );
    // 最多 accountDeviceLimit 把：多出来的按最后登录时间删最旧的（走 idx_account，行数有界）。
    const stale = (await manager.query('SELECT id FROM account_device WHERE account_id = ? ORDER BY update_time DESC, id DESC LIMIT 100 OFFSET ?', [accountId, accountDeviceLimit])) as { id: string }[];
    if (stale.length > 0) await manager.query('DELETE FROM account_device WHERE id IN (?)', [stale.map((row) => row.id)]);
  }

  async summaryOf(deviceId: string, now: Date) {
    const linked = (await this.accounts.query('SELECT account_id AS accountId FROM account_device WHERE device_id = ?', [deviceId])) as { accountId: string }[];
    const accountId = linked[0]?.accountId;
    if (accountId === undefined) return null;
    const account = await this.accounts.findOne({ where: { accountId } });
    if (account === null) return null;
    const [count] = (await this.accounts.query('SELECT COUNT(*) AS total FROM account_device WHERE account_id = ?', [accountId])) as { total: string }[];
    await this.accounts.update({ accountId }, { lastSeenTime: now, updateTime: now });
    return { accountId, username: account.username, deviceCount: Number(count.total), createTime: account.createTime };
  }

  async accountOf(deviceId: string) {
    const linked = (await this.accounts.query('SELECT account_id AS accountId FROM account_device WHERE device_id = ?', [deviceId])) as { accountId: string }[];
    return linked[0]?.accountId ?? null;
  }

  deleteOf(deviceId: string) {
    return this.accounts.manager.transaction(async (manager) => {
      const linked = (await manager.query('SELECT account_id AS accountId FROM account_device WHERE device_id = ?', [deviceId])) as { accountId: string }[];
      const accountId = linked[0]?.accountId;
      if (accountId === undefined) return false;
      // 墓碑：这个账号的每把密钥一行（最多 accountDeviceLimit 行），之后再来的回 ACCOUNT_DELETED。
      const now = new Date();
      await manager.query(
        'INSERT INTO account_tombstone (device_id, create_time, update_time) SELECT device_id, ?, ? FROM account_device WHERE account_id = ? ON DUPLICATE KEY UPDATE create_time = VALUES(create_time), update_time = VALUES(update_time)',
        [now, now, accountId],
      );
      await this.removeAccounts(manager, [accountId]);
      return true;
    });
  }

  async deletedOf(deviceId: string) {
    return ((await this.accounts.query('SELECT id FROM account_tombstone WHERE device_id = ? LIMIT 1', [deviceId])) as unknown[]).length > 0;
  }

  // 一条语句：按 uk_device 找到登记、按主键改账号，不先查账号号。
  async touchOf(deviceId: string, now: Date) {
    await this.accounts.query('UPDATE app_account a JOIN account_device d ON d.account_id = a.account_id SET a.last_seen_time = ?, a.update_time = ? WHERE d.device_id = ?', [now, now, deviceId]);
  }

  async deleteTombstones(before: Date, limit: number) {
    const deleted = (await this.accounts.query('DELETE FROM account_tombstone WHERE create_time < ? ORDER BY create_time LIMIT ?', [before, limit])) as { affectedRows: number };
    return deleted.affectedRows;
  }

  async unlinkDevices(deviceIds: string[], manager: EntityManager) {
    if (deviceIds.length > 0) await manager.query('DELETE FROM account_device WHERE device_id IN (?)', [deviceIds]);
  }

  async deleteIdle(before: Date, limit: number) {
    const idle = (await this.accounts.query('SELECT account_id AS accountId FROM app_account WHERE last_seen_time < ? ORDER BY last_seen_time LIMIT ?', [before, limit])) as { accountId: string }[];
    // 账号下的私信设备连带它的好友关系与信箱一起删（每台约 2000 行，见 AccountDataHooks），同不活跃设备按 deviceRemovalChunk 个一个事务，单个事务行数有界。
    for (let start = 0; start < idle.length; start += deviceRemovalChunk) {
      const chunk = idle.slice(start, start + deviceRemovalChunk).map((row) => row.accountId);
      await this.accounts.manager.transaction((manager) => this.removeAccounts(manager, chunk));
    }
    return idle.length;
  }

  // 账号下的积分、挑战、解锁、诊断包认领与私信设备由登记的删除函数在同一事务里删（AccountDataHooks）；400 天没活跃的账号，积分流水早已满 13 个月删掉，剩下的行有界。
  private async removeAccounts(manager: EntityManager, accountIds: string[]) {
    await this.hooks.run(manager, accountIds);
    await manager.query('DELETE FROM account_device WHERE account_id IN (?)', [accountIds]);
    await manager.query('DELETE FROM app_account WHERE account_id IN (?)', [accountIds]);
  }
}
