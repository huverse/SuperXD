import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { randomBytes } from 'node:crypto';
import { EntityManager, Repository } from 'typeorm';

import { accountDeviceLimit } from 'src/common/relay_limits';
import { AppAccountEntity } from 'src/modules/account/account.entity';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';

export type AccountSummary = { accountId: string; providers: string[]; deviceCount: number; createTime: Date };

// 账号存储端口：服务只依赖这个抽象。
export abstract class AccountRepository {
  // 按登录方式与主体哈希找账号，没有就新建；再把这把设备密钥登记到账号下（一把密钥只属于一个账号，原来属于别的账号就改过来）。
  // 账号下的密钥超过上限时删掉最久没用的。同一事务；并发新建同一主体只会建出一个账号。
  abstract signIn(provider: string, subjectHash: string, deviceId: string, now: Date): Promise<{ accountId: string; created: boolean }>;
  // 这把密钥所在的账号，顺带记最后活跃；没登录返回 null。
  abstract summaryOf(deviceId: string, now: Date): Promise<AccountSummary | null>;
  // 这把密钥所在的账号号（积分、挑战按它认人），只读不记活跃；没登录返回 null。
  abstract accountOf(deviceId: string): Promise<string | null>;
  // 这把密钥所在账号最早的那条登录方式（「登录方式\n主体哈希」），节日抽奖按它认人：注销后用同一身份重建账号还是同一个人。没登录返回 null。
  abstract identityKeyOf(deviceId: string): Promise<string | null>;
  // 注销这把密钥所在的账号：登录方式、全部密钥的登记与账号本身。没登录返回 false。
  abstract deleteOf(deviceId: string): Promise<boolean>;
  // 删设备时连带删登记，须在调用方事务内（跨领域的设备删除由 pairing 编排）。
  abstract unlinkDevices(deviceIds: string[], manager: EntityManager): Promise<void>;
  // 删最多 limit 个最后活跃早于 before 的账号（连同登录方式与密钥登记），返回删掉的个数。
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

  signIn(provider: string, subjectHash: string, deviceId: string, now: Date) {
    return this.accounts.manager.transaction(async (manager) => {
      let created = false;
      let accountId = await this.accountOfSubject(manager, provider, subjectHash);
      if (accountId === null) {
        // 先占登录方式这一行（唯一键 provider + subject_hash），抢到的才建账号；并发的另一个读到已有的那个。
        const candidate = randomBytes(16).toString('base64url');
        const inserted = (await manager.query(
          'INSERT IGNORE INTO account_identity (account_id, provider, subject_hash, create_time, update_time) VALUES (?, ?, ?, ?, ?)',
          [candidate, provider, subjectHash, now, now],
        )) as { affectedRows: number };
        if (inserted.affectedRows === 1) {
          await manager.query('INSERT INTO app_account (account_id, last_seen_time, create_time, update_time) VALUES (?, ?, ?, ?)', [candidate, now, now, now]);
          accountId = candidate;
          created = true;
        } else {
          accountId = (await this.accountOfSubject(manager, provider, subjectHash))!;
        }
      }
      await manager.query(
        'INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE account_id = VALUES(account_id), update_time = VALUES(update_time)',
        [accountId, deviceId, now, now],
      );
      // 最多 accountDeviceLimit 把：多出来的按最后登录时间删最旧的（走 idx_account，行数有界）。
      const stale = (await manager.query('SELECT id FROM account_device WHERE account_id = ? ORDER BY update_time DESC, id DESC LIMIT 100 OFFSET ?', [accountId, accountDeviceLimit])) as { id: string }[];
      if (stale.length > 0) await manager.query('DELETE FROM account_device WHERE id IN (?)', [stale.map((row) => row.id)]);
      if (!created) await manager.query('UPDATE app_account SET last_seen_time = ?, update_time = ? WHERE account_id = ?', [now, now, accountId]);
      return { accountId, created };
    });
  }

  private async accountOfSubject(manager: EntityManager, provider: string, subjectHash: string) {
    const rows = (await manager.query('SELECT account_id AS accountId FROM account_identity WHERE provider = ? AND subject_hash = ?', [provider, subjectHash])) as { accountId: string }[];
    return rows[0]?.accountId ?? null;
  }

  async summaryOf(deviceId: string, now: Date) {
    const linked = (await this.accounts.query('SELECT account_id AS accountId FROM account_device WHERE device_id = ?', [deviceId])) as { accountId: string }[];
    const accountId = linked[0]?.accountId;
    if (accountId === undefined) return null;
    const account = await this.accounts.findOne({ where: { accountId } });
    if (account === null) return null;
    const providers = (await this.accounts.query('SELECT provider FROM account_identity WHERE account_id = ? ORDER BY id', [accountId])) as { provider: string }[];
    const [count] = (await this.accounts.query('SELECT COUNT(*) AS total FROM account_device WHERE account_id = ?', [accountId])) as { total: string }[];
    await this.accounts.update({ accountId }, { lastSeenTime: now, updateTime: now });
    return { accountId, providers: providers.map((row) => row.provider), deviceCount: Number(count.total), createTime: account.createTime };
  }

  async accountOf(deviceId: string) {
    const linked = (await this.accounts.query('SELECT account_id AS accountId FROM account_device WHERE device_id = ?', [deviceId])) as { accountId: string }[];
    return linked[0]?.accountId ?? null;
  }

  async identityKeyOf(deviceId: string) {
    const accountId = await this.accountOf(deviceId);
    if (accountId === null) return null;
    const rows = (await this.accounts.query('SELECT provider, subject_hash AS subjectHash FROM account_identity WHERE account_id = ? ORDER BY id LIMIT 1', [accountId])) as { provider: string; subjectHash: string }[];
    return rows[0] === undefined ? null : `${rows[0].provider}\n${rows[0].subjectHash}`;
  }

  deleteOf(deviceId: string) {
    return this.accounts.manager.transaction(async (manager) => {
      const linked = (await manager.query('SELECT account_id AS accountId FROM account_device WHERE device_id = ?', [deviceId])) as { accountId: string }[];
      const accountId = linked[0]?.accountId;
      if (accountId === undefined) return false;
      await this.removeAccounts(manager, [accountId]);
      return true;
    });
  }

  async unlinkDevices(deviceIds: string[], manager: EntityManager) {
    if (deviceIds.length > 0) await manager.query('DELETE FROM account_device WHERE device_id IN (?)', [deviceIds]);
  }

  async deleteIdle(before: Date, limit: number) {
    const idle = (await this.accounts.query('SELECT account_id AS accountId FROM app_account WHERE last_seen_time < ? ORDER BY last_seen_time LIMIT ?', [before, limit])) as { accountId: string }[];
    // 每个账号最多 accountDeviceLimit 条登记与几条登录方式，按 100 个一个事务删，单个事务行数有界。
    for (let start = 0; start < idle.length; start += 100) {
      const chunk = idle.slice(start, start + 100).map((row) => row.accountId);
      await this.accounts.manager.transaction((manager) => this.removeAccounts(manager, chunk));
    }
    return idle.length;
  }

  // 账号下的积分与挑战由登记的删除函数在同一事务里删（AccountDataHooks）；400 天没活跃的账号，积分流水早已满 13 个月删掉，剩下的行有界。
  private async removeAccounts(manager: EntityManager, accountIds: string[]) {
    await this.hooks.run(manager, accountIds);
    await manager.query('DELETE FROM account_device WHERE account_id IN (?)', [accountIds]);
    await manager.query('DELETE FROM account_identity WHERE account_id IN (?)', [accountIds]);
    await manager.query('DELETE FROM app_account WHERE account_id IN (?)', [accountIds]);
  }
}
