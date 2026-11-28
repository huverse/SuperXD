import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';

import { AccountHold, AccountHoldAll } from 'src/modules/account/account.repository';
import { AccountUnlockEntity } from 'src/modules/unlock/unlock.entity';

export type UnlockRow = { id: string; accountId: string; unlockId: string; source: string; price: number };

// 解锁存储端口：服务只依赖这个抽象。
export abstract class UnlockRepository {
  // 这个账号记过的解锁里属于 unlockIds 的（走 (account_id, unlock_id) 唯一键，行数不超过配置里的项数）。
  abstract ownedOf(accountId: string, unlockIds: string[]): Promise<Set<string>>;
  // 记下抽中的（已有就不动）。
  // hold 是账号写入门禁（AccountRepository.hold），事务的第一步（下同）。
  abstract insertDrawn(accountId: string, unlockIds: string[], now: Date, hold: AccountHold): Promise<void>;
  // 在事务里记一笔买的：已经记过（买过或抽中过）返回 null，否则返回这一行的编号，再在同一事务里调 charge（付积分），charge 抛错则不留。
  abstract buy(accountId: string, unlockId: string, price: number, now: Date, hold: AccountHold, charge: (manager: EntityManager, rowId: string) => Promise<void>): Promise<string | null>;
  // 在事务里取最多 limit 行属于这些解锁的记录交给 work（下架退回用），work 之后这些行删掉；返回这一批取到的行数（不足 limit 说明取完了）。
  // holdAll 是账号写入门禁（AccountRepository.holdAll）：先锁这批记录所属的账号行、再锁记录（同注销的先后，11-28 复核 F05），交给 work 的只有账号还在的行。
  abstract settle(unlockIds: string[], limit: number, holdAll: AccountHoldAll, work: (manager: EntityManager, rows: UnlockRow[]) => Promise<void>): Promise<number>;
  // 删最多 limit 行属于这些解锁的记录（公开满 30 天的），返回删的行数。
  abstract deleteOf(unlockIds: string[], limit: number): Promise<number>;
  abstract deleteAccounts(manager: EntityManager, accountIds: string[]): Promise<void>;
}

@Injectable()
export class TypeormUnlockRepository extends UnlockRepository {
  constructor(@InjectRepository(AccountUnlockEntity) private readonly unlocks: Repository<AccountUnlockEntity>) {
    super();
  }

  async ownedOf(accountId: string, unlockIds: string[]) {
    if (unlockIds.length === 0) return new Set<string>();
    const rows = (await this.unlocks.query('SELECT unlock_id AS unlockId FROM account_unlock WHERE account_id = ? AND unlock_id IN (?)', [accountId, unlockIds])) as { unlockId: string }[];
    return new Set(rows.map((row) => row.unlockId));
  }

  async insertDrawn(accountId: string, unlockIds: string[], now: Date, hold: AccountHold) {
    if (unlockIds.length === 0) return;
    await this.unlocks.manager.transaction(async (manager) => {
      await hold(manager, accountId);
      await manager.query(
        `INSERT IGNORE INTO account_unlock (account_id, unlock_id, source, price, create_time, update_time) VALUES ${unlockIds.map(() => '(?, ?, ?, 0, ?, ?)').join(', ')}`,
        unlockIds.flatMap((unlockId) => [accountId, unlockId, 'drawn', now, now]),
      );
    });
  }

  buy(accountId: string, unlockId: string, price: number, now: Date, hold: AccountHold, charge: (manager: EntityManager, rowId: string) => Promise<void>) {
    return this.unlocks.manager.transaction(async (manager) => {
      await hold(manager, accountId);
      const inserted = (await manager.query('INSERT IGNORE INTO account_unlock (account_id, unlock_id, source, price, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?)', [
        accountId,
        unlockId,
        'buy',
        price,
        now,
        now,
      ])) as { affectedRows: number; insertId: number | string };
      if (inserted.affectedRows !== 1) return null;
      const rowId = String(inserted.insertId);
      await charge(manager, rowId);
      return rowId;
    });
  }

  settle(unlockIds: string[], limit: number, holdAll: AccountHoldAll, work: (manager: EntityManager, rows: UnlockRow[]) => Promise<void>) {
    if (unlockIds.length === 0) return Promise.resolve(0);
    return this.unlocks.manager.transaction(async (manager) => {
      // 先不加锁地取这一批（快照读），锁上它们的账号行，再锁住记录重读：等锁期间账号注销提交了的，记录已随账号删掉、重读不到。
      const batch = (await manager.query('SELECT id, account_id AS accountId FROM account_unlock WHERE unlock_id IN (?) ORDER BY id LIMIT ?', [unlockIds, limit])) as { id: string; accountId: string }[];
      if (batch.length === 0) return 0;
      const held = await holdAll(manager, batch.map((row) => row.accountId));
      const rows = (await manager.query('SELECT id, account_id AS accountId, unlock_id AS unlockId, source, price FROM account_unlock WHERE id IN (?) FOR UPDATE', [batch.map((row) => row.id)])) as UnlockRow[];
      if (rows.length > 0) {
        await work(manager, rows.filter((row) => held.has(row.accountId)).map((row) => ({ ...row, id: String(row.id), price: Number(row.price) })));
        await manager.query('DELETE FROM account_unlock WHERE id IN (?)', [rows.map((row) => row.id)]);
      }
      return batch.length;
    });
  }

  async deleteOf(unlockIds: string[], limit: number) {
    if (unlockIds.length === 0) return 0;
    const result = (await this.unlocks.query('DELETE FROM account_unlock WHERE unlock_id IN (?) ORDER BY id LIMIT ?', [unlockIds, limit])) as { affectedRows: number };
    return result.affectedRows;
  }

  async deleteAccounts(manager: EntityManager, accountIds: string[]) {
    if (accountIds.length === 0) return;
    await manager.query('DELETE FROM account_unlock WHERE account_id IN (?)', [accountIds]);
  }
}
