import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';

import { PointsGrantEntity } from 'src/modules/points/points.entity';

export type PointsGrantInput = { accountId: string; amount: number; source: string; sourceKey: string; note: string; now: Date; expireTime: Date };
export type PointsBalance = { balance: number; expiring: number; expiringAt: Date | null };
export type PointsEntryRow = { id: string; kind: string; amount: number; note: string; createTime: Date };

// 积分存储端口：服务只依赖这个抽象。
export abstract class PointsRepository {
  // 记一笔获得与对应的流水，须在调用方事务内（挑战结算与这一笔同一事务）。同一来源同一个键已记过就不再记，返回 false。
  abstract grant(manager: EntityManager, input: PointsGrantInput): Promise<boolean>;
  // 余额（没过期的剩余之和）与 within 之内要过期的合计、其中最早的过期时刻；走 (account_id, expire_time) 索引，行数是这个账号 12 个月里的获得笔数。
  abstract balanceOf(accountId: string, now: Date, within: Date): Promise<PointsBalance>;
  // 流水从新到旧，before 是上一页最后一条的编号（按 id 游标，不用 OFFSET）。
  abstract entriesOf(accountId: string, before: string | null, limit: number): Promise<PointsEntryRow[]>;
  // 把最多 limit 笔到期还有剩余的获得清零，每笔记一条过期流水，返回处理的笔数。
  abstract expireDue(now: Date, limit: number): Promise<number>;
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
      'SELECT COALESCE(SUM(remaining), 0) AS balance, COALESCE(SUM(CASE WHEN expire_time <= ? THEN remaining ELSE 0 END), 0) AS expiring, MIN(CASE WHEN expire_time <= ? AND remaining > 0 THEN expire_time END) AS expiringAt FROM points_grant WHERE account_id = ? AND expire_time > ?',
      [within, within, accountId, now],
    )) as { balance: string; expiring: string; expiringAt: Date | null }[];
    return { balance: Number(row.balance), expiring: Number(row.expiring), expiringAt: row.expiringAt };
  }

  async entriesOf(accountId: string, before: string | null, limit: number) {
    const rows = (await this.grants.query(
      `SELECT id, kind, amount, note, create_time AS createTime FROM points_entry WHERE account_id = ?${before === null ? '' : ' AND id < ?'} ORDER BY id DESC LIMIT ?`,
      before === null ? [accountId, limit] : [accountId, before, limit],
    )) as { id: string; kind: string; amount: number; note: string; createTime: Date }[];
    return rows.map((row) => ({ ...row, id: String(row.id) }));
  }

  expireDue(now: Date, limit: number) {
    return this.grants.manager.transaction(async (manager) => {
      const due = (await manager.query('SELECT id, account_id AS accountId, remaining FROM points_grant WHERE expire_time <= ? AND remaining > 0 ORDER BY expire_time LIMIT ? FOR UPDATE', [now, limit])) as {
        id: string;
        accountId: string;
        remaining: number;
      }[];
      if (due.length === 0) return 0;
      const placeholders = due.map(() => '(?, ?, ?, ?, ?, ?, ?)').join(', ');
      await manager.query(
        `INSERT INTO points_entry (account_id, kind, amount, note, ref, create_time, update_time) VALUES ${placeholders}`,
        due.flatMap((row) => [row.accountId, 'expire', -row.remaining, '积分到期', `grant:${row.id}`, now, now]),
      );
      await manager.query('UPDATE points_grant SET remaining = 0, update_time = ? WHERE id IN (?)', [now, due.map((row) => row.id)]);
      return due.length;
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
