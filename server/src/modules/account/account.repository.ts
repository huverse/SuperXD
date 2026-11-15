import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { randomBytes } from 'node:crypto';
import { EntityManager, Repository } from 'typeorm';

import { accountDeviceLimit } from 'src/common/relay_limits';
import { AppAccountEntity } from 'src/modules/account/account.entity';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';

export type AccountSummary = { accountId: string; providers: string[]; deviceCount: number; createTime: Date };
export type RecoveryRow = { id: string; accountId: string; deviceId: string; state: 'pending' | 'granted' | 'denied' | 'conflict'; createTime: Date };

// 账号存储端口：服务只依赖这个抽象。
export abstract class AccountRepository {
  // 按登录方式与主体哈希找账号，没有就新建；再把这把设备密钥登记到账号下（一把密钥只属于一个账号，原来属于别的账号就改过来）。
  // 账号下的密钥超过上限时删掉最久没用的。同一事务；并发新建同一主体只会建出一个账号。
  abstract signIn(provider: string, subjectHash: string, deviceId: string, now: Date): Promise<{ accountId: string; created: boolean }>;
  // 设备核对：这个主体还没有账号就新建，已有账号但一把设备密钥都没登着（都退出了）就登回去，两种都登记这把设备密钥；
  // 已有账号且还有设备登着返回 null、什么都不改（要扫码授权或申请找回）。并发新建只会建出一个。
  abstract claim(provider: string, subjectHash: string, deviceId: string, now: Date): Promise<{ accountId: string; created: boolean } | null>;
  // 把一把设备密钥登记到已有账号下（扫码授权；原来属于别的账号就改过来，超过上限删最久没用的）。账号不在了返回 false。
  abstract link(accountId: string, deviceId: string, now: Date): Promise<boolean>;
  // 这把密钥所在的账号与它在这种登录方式下的主体哈希（扫码授权核对两边是同一个人）；没登录或没有这种登录方式返回 null。
  abstract subjectOf(deviceId: string, provider: string): Promise<{ accountId: string; subjectHash: string } | null>;
  // 这把密钥所在账号的建立时刻；没登录返回 null。
  abstract createdOf(deviceId: string): Promise<Date | null>;
  // 这个主体的账号号与它现在登录着几把设备密钥；没有账号返回 null。
  abstract accountOfSubject(provider: string, subjectHash: string): Promise<{ accountId: string; devices: number } | null>;
  // 提交找回申请：这台设备对这个账号已有等待中的就返回那一条，否则新建。
  abstract requestRecovery(accountId: string, deviceId: string, now: Date): Promise<RecoveryRow>;
  // 这台设备最近一次提交的找回申请；没有返回 null。
  abstract recoveryOfDevice(deviceId: string): Promise<RecoveryRow | null>;
  // 账号下等待中的找回申请，从早到晚，最多 limit 条。
  abstract pendingRecoveries(accountId: string, limit: number): Promise<RecoveryRow[]>;
  // 把账号下一条等待中的申请改成 denied 或 granted（granted 同时登记申请那台设备）；不是等待中或不属于这个账号返回 false。
  abstract decideRecovery(recoveryId: string, accountId: string, state: 'denied' | 'granted', now: Date): Promise<boolean>;
  // 到期的申请：账号下只有它一条在等就生效（登记设备），还有别的设备在等就把这些都改成 conflict。返回结果状态。
  abstract settleRecovery(row: RecoveryRow, now: Date): Promise<RecoveryRow['state']>;
  // 删最多 limit 条早于 before 提交的找回申请，返回删掉的条数。
  abstract deleteRecoveriesBefore(before: Date, limit: number): Promise<number>;
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

  claim(provider: string, subjectHash: string, deviceId: string, now: Date) {
    return this.accounts.manager.transaction(async (manager) => {
      const candidate = randomBytes(16).toString('base64url');
      // 唯一键 provider + subject_hash：抢到这一行的才建账号；已有（含并发的另一个先建了）就看它还有没有设备登着。
      const inserted = (await manager.query(
        'INSERT IGNORE INTO account_identity (account_id, provider, subject_hash, create_time, update_time) VALUES (?, ?, ?, ?, ?)',
        [candidate, provider, subjectHash, now, now],
      )) as { affectedRows: number };
      if (inserted.affectedRows === 1) {
        await manager.query('INSERT INTO app_account (account_id, last_seen_time, create_time, update_time) VALUES (?, ?, ?, ?)', [candidate, now, now, now]);
        await this.linkIn(manager, candidate, deviceId, now);
        return { accountId: candidate, created: true };
      }
      const accountId = (await this.accountIdOfSubject(manager, provider, subjectHash))!;
      // 锁住账号行再数设备：和扫码授权、找回生效并发时不会算错。
      await manager.query('SELECT id FROM app_account WHERE account_id = ? FOR UPDATE', [accountId]);
      const linked = (await manager.query('SELECT device_id AS deviceId FROM account_device WHERE account_id = ? LIMIT 1', [accountId])) as { deviceId: string }[];
      if (linked.length > 0 && linked[0].deviceId !== deviceId) return null;
      await manager.query('UPDATE app_account SET last_seen_time = ?, update_time = ? WHERE account_id = ?', [now, now, accountId]);
      await this.linkIn(manager, accountId, deviceId, now);
      return { accountId, created: false };
    });
  }

  link(accountId: string, deviceId: string, now: Date) {
    return this.accounts.manager.transaction(async (manager) => {
      const updated = (await manager.query('UPDATE app_account SET last_seen_time = ?, update_time = ? WHERE account_id = ?', [now, now, accountId])) as { affectedRows: number };
      if (updated.affectedRows !== 1) return false;
      await this.linkIn(manager, accountId, deviceId, now);
      return true;
    });
  }

  async subjectOf(deviceId: string, provider: string) {
    const rows = (await this.accounts.query(
      'SELECT d.account_id AS accountId, i.subject_hash AS subjectHash FROM account_device d JOIN account_identity i ON i.account_id = d.account_id AND i.provider = ? WHERE d.device_id = ? LIMIT 1',
      [provider, deviceId],
    )) as { accountId: string; subjectHash: string }[];
    return rows[0] ?? null;
  }

  async createdOf(deviceId: string) {
    const rows = (await this.accounts.query('SELECT a.create_time AS createTime FROM account_device d JOIN app_account a ON a.account_id = d.account_id WHERE d.device_id = ? LIMIT 1', [deviceId])) as { createTime: Date }[];
    return rows[0]?.createTime ?? null;
  }

  async accountOfSubject(provider: string, subjectHash: string) {
    const rows = (await this.accounts.query(
      'SELECT i.account_id AS accountId, (SELECT COUNT(*) FROM account_device d WHERE d.account_id = i.account_id) AS devices FROM account_identity i WHERE i.provider = ? AND i.subject_hash = ?',
      [provider, subjectHash],
    )) as { accountId: string; devices: string }[];
    return rows[0] === undefined ? null : { accountId: rows[0].accountId, devices: Number(rows[0].devices) };
  }

  requestRecovery(accountId: string, deviceId: string, now: Date) {
    return this.accounts.manager.transaction(async (manager) => {
      const existing = await this.recoveryRows(manager, 'SELECT id, account_id AS accountId, device_id AS deviceId, state, create_time AS createTime FROM account_recovery WHERE account_id = ? AND device_id = ? AND state = ? LIMIT 1', [accountId, deviceId, 'pending']);
      if (existing[0] !== undefined) return existing[0];
      const inserted = (await manager.query('INSERT INTO account_recovery (account_id, device_id, state, create_time, update_time) VALUES (?, ?, ?, ?, ?)', [accountId, deviceId, 'pending', now, now])) as { insertId: number | string };
      return { id: String(inserted.insertId), accountId, deviceId, state: 'pending' as const, createTime: now };
    });
  }

  async recoveryOfDevice(deviceId: string) {
    const rows = await this.recoveryRows(this.accounts.manager, 'SELECT id, account_id AS accountId, device_id AS deviceId, state, create_time AS createTime FROM account_recovery WHERE device_id = ? ORDER BY id DESC LIMIT 1', [deviceId]);
    return rows[0] ?? null;
  }

  pendingRecoveries(accountId: string, limit: number) {
    return this.recoveryRows(this.accounts.manager, 'SELECT id, account_id AS accountId, device_id AS deviceId, state, create_time AS createTime FROM account_recovery WHERE account_id = ? AND state = ? ORDER BY id LIMIT ?', [accountId, 'pending', limit]);
  }

  decideRecovery(recoveryId: string, accountId: string, state: 'denied' | 'granted', now: Date) {
    return this.accounts.manager.transaction(async (manager) => {
      const rows = await this.recoveryRows(manager, 'SELECT id, account_id AS accountId, device_id AS deviceId, state, create_time AS createTime FROM account_recovery WHERE id = ? AND account_id = ? AND state = ? FOR UPDATE', [recoveryId, accountId, 'pending']);
      const row = rows[0];
      if (row === undefined) return false;
      await manager.query('UPDATE account_recovery SET state = ?, update_time = ? WHERE id = ?', [state, now, row.id]);
      if (state === 'granted') await this.linkIn(manager, accountId, row.deviceId, now);
      return true;
    });
  }

  settleRecovery(row: RecoveryRow, now: Date) {
    return this.accounts.manager.transaction(async (manager) => {
      // 锁住这个账号下等待中的申请再判：同时到期的两台设备只会有一个结果。
      const pending = await this.recoveryRows(manager, 'SELECT id, account_id AS accountId, device_id AS deviceId, state, create_time AS createTime FROM account_recovery WHERE account_id = ? AND state = ? ORDER BY id LIMIT 100 FOR UPDATE', [row.accountId, 'pending']);
      if (!pending.some((item) => item.id === row.id)) return (await this.recoveryRows(manager, 'SELECT id, account_id AS accountId, device_id AS deviceId, state, create_time AS createTime FROM account_recovery WHERE id = ?', [row.id]))[0]?.state ?? 'denied';
      if (pending.some((item) => item.deviceId !== row.deviceId)) {
        await manager.query('UPDATE account_recovery SET state = ?, update_time = ? WHERE id IN (?)', ['conflict', now, pending.map((item) => item.id)]);
        return 'conflict' as const;
      }
      const alive = (await manager.query('UPDATE app_account SET last_seen_time = ?, update_time = ? WHERE account_id = ?', [now, now, row.accountId])) as { affectedRows: number };
      if (alive.affectedRows !== 1) {
        await manager.query('UPDATE account_recovery SET state = ?, update_time = ? WHERE id = ?', ['denied', now, row.id]);
        return 'denied' as const;
      }
      await manager.query('UPDATE account_recovery SET state = ?, update_time = ? WHERE id = ?', ['granted', now, row.id]);
      await this.linkIn(manager, row.accountId, row.deviceId, now);
      return 'granted' as const;
    });
  }

  async deleteRecoveriesBefore(before: Date, limit: number) {
    const rows = (await this.accounts.query('SELECT id FROM account_recovery WHERE create_time < ? ORDER BY create_time LIMIT ?', [before, limit])) as { id: string }[];
    if (rows.length > 0) await this.accounts.query('DELETE FROM account_recovery WHERE id IN (?)', [rows.map((row) => row.id)]);
    return rows.length;
  }

  private async recoveryRows(manager: EntityManager, sql: string, params: unknown[]) {
    const rows = (await manager.query(sql, params)) as { id: string | number; accountId: string; deviceId: string; state: RecoveryRow['state']; createTime: Date }[];
    return rows.map((row) => ({ ...row, id: String(row.id) }));
  }

  // 登记设备密钥（一把只属于一个账号）并把账号下的密钥压到上限以内，须在调用方事务内。
  private async linkIn(manager: EntityManager, accountId: string, deviceId: string, now: Date) {
    await manager.query(
      'INSERT INTO account_device (account_id, device_id, create_time, update_time) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE account_id = VALUES(account_id), update_time = VALUES(update_time)',
      [accountId, deviceId, now, now],
    );
    // 最多 accountDeviceLimit 把：多出来的按最后登录时间删最旧的（走 idx_account，行数有界）。
    const stale = (await manager.query('SELECT id FROM account_device WHERE account_id = ? ORDER BY update_time DESC, id DESC LIMIT 100 OFFSET ?', [accountId, accountDeviceLimit])) as { id: string }[];
    if (stale.length > 0) await manager.query('DELETE FROM account_device WHERE id IN (?)', [stale.map((row) => row.id)]);
  }

  signIn(provider: string, subjectHash: string, deviceId: string, now: Date) {
    return this.accounts.manager.transaction(async (manager) => {
      let created = false;
      let accountId = await this.accountIdOfSubject(manager, provider, subjectHash);
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
          accountId = (await this.accountIdOfSubject(manager, provider, subjectHash))!;
        }
      }
      await this.linkIn(manager, accountId, deviceId, now);
      if (!created) await manager.query('UPDATE app_account SET last_seen_time = ?, update_time = ? WHERE account_id = ?', [now, now, accountId]);
      return { accountId, created };
    });
  }

  private async accountIdOfSubject(manager: EntityManager, provider: string, subjectHash: string) {
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
    await manager.query('DELETE FROM account_recovery WHERE account_id IN (?)', [accountIds]);
    await manager.query('DELETE FROM account_device WHERE account_id IN (?)', [accountIds]);
    await manager.query('DELETE FROM account_identity WHERE account_id IN (?)', [accountIds]);
    await manager.query('DELETE FROM app_account WHERE account_id IN (?)', [accountIds]);
  }
}
