import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';

import { AccountHoldAll } from 'src/modules/account/account.repository';
import { PointsGrantEntity } from 'src/modules/points/points.entity';

export type PointsGrantInput = { accountId: string; amount: number; source: string; sourceKey: string; note: string; now: Date; expireTime: Date };
export type PointsBalance = { balance: number; expiring: number; expiringAt: Date | null; earned: number };
export type PointsSpendInput = { accountId: string; amount: number; ref: string; note: string; now: Date };
export type PointsRefund = { accountId: string; amount: number; sourceKey: string; note: string };
export type PointsEntryRow = { id: string; kind: string; amount: number; note: string; createTime: Date };

// 积分存储端口：服务只依赖这个抽象。
export abstract class PointsRepository {
  // 记一笔获得与对应的流水，须在调用方事务内（挑战结算与这一笔同一事务）。同一来源同一个键已记过就不再记，返回 false。
  abstract grant(manager: EntityManager, input: PointsGrantInput): Promise<boolean>;
  // 退回一批（调用方事务内）：每笔记成来源 refund 的获得（同样满 12 个月过期，不算进等级）与一条退回流水；同一个键只记一次。
  abstract refundAll(manager: EntityManager, refunds: PointsRefund[], now: Date, expireTime: Date): Promise<void>;
  // 余额（没过期的剩余之和）、within 之内要过期的合计与其中最早的过期时刻、没过期的获得总数（算等级，花了不减、退回的不算）；
  // 走 (account_id, expire_time) 索引，行数是这个账号 12 个月里的获得笔数。
  abstract balanceOf(accountId: string, now: Date, within: Date): Promise<PointsBalance>;
  // 花一笔（调用方事务内）：先扣快过期的，记一条花费流水；余额不够不扣、返回 false。
  abstract spend(manager: EntityManager, input: PointsSpendInput): Promise<boolean>;
  // 流水从新到旧，before 是上一页最后一条的编号（按 id 游标，不用 OFFSET）。
  abstract entriesOf(accountId: string, before: string | null, limit: number): Promise<PointsEntryRow[]>;
  // 把最多 limit 笔到期还有剩余的获得清零，每笔记一条过期流水，返回这一批取到的笔数（不足 limit 说明取完了）。
  // holdAll 是账号写入门禁（AccountRepository.holdAll）：先锁这批获得所属的账号行、再锁获得（同注销的先后，11-28 复核 F05），已注销账号的不记流水。
  abstract expireDue(now: Date, limit: number, holdAll: AccountHoldAll): Promise<number>;
  // 删最多 limit 条早于 before 的流水 / 剩余为 0 且过期早于 before 的获得，返回删的行数。
  abstract deleteEntriesBefore(before: Date, limit: number): Promise<number>;
  abstract deleteGrantsBefore(before: Date, limit: number): Promise<number>;
  // 注销或清理账号时连带删除，须在调用方事务内。
  abstract deleteAccounts(manager: EntityManager, accountIds: string[]): Promise<void>;
}

@Injectable()
export class TypeormPointsRepository extends PointsRepository {
  constructor(@InjectRepository(PointsGrantEntity) private readonly grants: Repository<PointsGrantEntity>) {
    super();
  }

  async grant(manager: EntityManager, input: PointsGrantInput) {
    const inserted = (await manager.query(
      'INSERT IGNORE INTO points_grant (account_id, amount, remaining, source, source_key, expire_time, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [input.accountId, input.amount, input.amount, input.source, input.sourceKey, input.expireTime, input.now, input.now],
    )) as { affectedRows: number; insertId: number };
    if (inserted.affectedRows !== 1) return false;
    await manager.query('INSERT INTO points_entry (account_id, kind, amount, note, ref, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?)', [
      input.accountId,
      'earn',
      input.amount,
      input.note,
      input.sourceKey,
      input.now,
      input.now,
    ]);
    return true;
  }

  async balanceOf(accountId: string, now: Date, within: Date) {
    const [row] = (await this.grants.query(
      `SELECT COALESCE(SUM(remaining), 0) AS balance, COALESCE(SUM(CASE WHEN expire_time <= ? THEN remaining ELSE 0 END), 0) AS expiring, MIN(CASE WHEN expire_time <= ? AND remaining > 0 THEN expire_time END) AS expiringAt, COALESCE(SUM(CASE WHEN source <> 'refund' THEN amount ELSE 0 END), 0) AS earned FROM points_grant WHERE account_id = ? AND expire_time > ?`,
      [within, within, accountId, now],
    )) as { balance: string; expiring: string; expiringAt: Date | null; earned: string }[];
    return { balance: Number(row.balance), expiring: Number(row.expiring), expiringAt: row.expiringAt, earned: Number(row.earned) };
  }

  async refundAll(manager: EntityManager, refunds: PointsRefund[], now: Date, expireTime: Date) {
    if (refunds.length === 0) return;
    await manager.query(
      `INSERT IGNORE INTO points_grant (account_id, amount, remaining, source, source_key, expire_time, create_time, update_time) VALUES ${refunds.map(() => '(?, ?, ?, ?, ?, ?, ?, ?)').join(', ')}`,
      refunds.flatMap((item) => [item.accountId, item.amount, item.amount, 'refund', item.sourceKey, expireTime, now, now]),
    );
    await manager.query(
      `INSERT INTO points_entry (account_id, kind, amount, note, ref, create_time, update_time) VALUES ${refunds.map(() => '(?, ?, ?, ?, ?, ?, ?)').join(', ')}`,
      refunds.flatMap((item) => [item.accountId, 'refund', item.amount, item.note, item.sourceKey, now, now]),
    );
  }

  async spend(manager: EntityManager, input: PointsSpendInput) {
    // 锁住这个账号还有剩余的获得（12 个月里的笔数，有界），按过期先后扣。
    const grants = (await manager.query('SELECT id, remaining FROM points_grant WHERE account_id = ? AND expire_time > ? AND remaining > 0 ORDER BY expire_time, id FOR UPDATE', [
      input.accountId,
      input.now,
    ])) as { id: string; remaining: number }[];
    const taken: { id: string; left: number }[] = [];
    let owed = input.amount;
    for (const grant of grants) {
      if (owed === 0) break;
      const take = Math.min(owed, grant.remaining);
      taken.push({ id: grant.id, left: grant.remaining - take });
      owed -= take;
    }
    if (owed > 0) return false;
    await manager.query(`UPDATE points_grant SET remaining = CASE id ${taken.map(() => 'WHEN ? THEN ?').join(' ')} END, update_time = ? WHERE id IN (?)`, [
      ...taken.flatMap((item) => [item.id, item.left]),
      input.now,
      taken.map((item) => item.id),
    ]);
    await manager.query('INSERT INTO points_entry (account_id, kind, amount, note, ref, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?)', [
      input.accountId,
      'spend',
      -input.amount,
      input.note,
      input.ref,
      input.now,
      input.now,
    ]);
    return true;
  }

  async entriesOf(accountId: string, before: string | null, limit: number) {
    const rows = (await this.grants.query(
      `SELECT id, kind, amount, note, create_time AS createTime FROM points_entry WHERE account_id = ?${before === null ? '' : ' AND id < ?'} ORDER BY id DESC LIMIT ?`,
      before === null ? [accountId, limit] : [accountId, before, limit],
    )) as { id: string; kind: string; amount: number; note: string; createTime: Date }[];
    return rows.map((row) => ({ ...row, id: String(row.id) }));
  }

  // 走 idx_due：虚拟列 due_time 只在还有剩余时有值，剩余为 0、过期后还留着的行不在索引范围里，每批只扫要清零的行。
  expireDue(now: Date, limit: number, holdAll: AccountHoldAll) {
    return this.grants.manager.transaction(async (manager) => {
      // 先快照读这一批、锁账号行，再锁住获得重读（还到期、账号还在的才记过期）；等锁期间注销提交了的，获得已随账号删掉。
      const batch = (await manager.query('SELECT id, account_id AS accountId FROM points_grant WHERE due_time <= ? ORDER BY due_time LIMIT ?', [now, limit])) as { id: string; accountId: string }[];
      if (batch.length === 0) return 0;
      const held = await holdAll(manager, batch.map((row) => row.accountId));
      const locked = (await manager.query('SELECT id, account_id AS accountId, remaining FROM points_grant WHERE id IN (?) AND due_time <= ? FOR UPDATE', [batch.map((row) => row.id), now])) as {
        id: string;
        accountId: string;
        remaining: number;
      }[];
      if (locked.length === 0) return batch.length;
      // 流水只给还在的账号记；账号已不在的孤儿行（门禁之前留下的）照样清零，不然一直留在到期索引里每轮都被选中。
      const due = locked.filter((row) => held.has(row.accountId));
      if (due.length > 0) {
        const placeholders = due.map(() => '(?, ?, ?, ?, ?, ?, ?)').join(', ');
        await manager.query(
          `INSERT INTO points_entry (account_id, kind, amount, note, ref, create_time, update_time) VALUES ${placeholders}`,
          due.flatMap((row) => [row.accountId, 'expire', -row.remaining, '积分到期', `grant:${row.id}`, now, now]),
        );
      }
      await manager.query('UPDATE points_grant SET remaining = 0, update_time = ? WHERE id IN (?)', [now, locked.map((row) => row.id)]);
      return batch.length;
    });
  }

  async deleteEntriesBefore(before: Date, limit: number) {
    const result = (await this.grants.query('DELETE FROM points_entry WHERE create_time < ? ORDER BY create_time LIMIT ?', [before, limit])) as { affectedRows: number };
    return result.affectedRows;
  }

  async deleteGrantsBefore(before: Date, limit: number) {
    const result = (await this.grants.query('DELETE FROM points_grant WHERE expire_time < ? AND remaining = 0 ORDER BY expire_time LIMIT ?', [before, limit])) as { affectedRows: number };
    return result.affectedRows;
  }

  async deleteAccounts(manager: EntityManager, accountIds: string[]) {
    if (accountIds.length === 0) return;
    await manager.query('DELETE FROM points_entry WHERE account_id IN (?)', [accountIds]);
    await manager.query('DELETE FROM points_grant WHERE account_id IN (?)', [accountIds]);
  }
}
