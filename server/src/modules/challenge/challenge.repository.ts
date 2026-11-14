import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';

import { ChallengeRunEntity } from 'src/modules/challenge/challenge.entity';

export type RunRow = {
  runId: string;
  accountId: string;
  challengeId: string;
  active: boolean;
  deadline: Date;
  plan: string;
  progress: string;
  ending: string | null;
  points: number | null;
  awarded: number | null;
  endTime: Date | null;
};

export type RunChanges = Pick<RunRow, 'progress'> & Partial<Pick<RunRow, 'ending' | 'points' | 'awarded' | 'endTime'>> & { settle?: boolean };

// 挑战存储端口：服务只依赖这个抽象。
export abstract class ChallengeRepository {
  // 插入一局；这个账号已有进行中的一局时插不进，返回 false。
  abstract insertRun(run: RunRow, now: Date): Promise<boolean>;
  abstract activeRunOf(accountId: string): Promise<string | null>;
  // 在事务里锁住这一局（只认这个账号的），交给 work 读改；没有这一局时 work 拿到 null。
  abstract withRun<T>(runId: string, accountId: string | null, work: (manager: EntityManager, run: RunRow | null) => Promise<T>): Promise<T>;
  // 写回这一局（work 里用）；settle 为真时同时把 active 清空（结算）。
  abstract updateRun(manager: EntityManager, runId: string, changes: RunChanges, now: Date): Promise<void>;
  // 这个账号在这些挑战上的最好成绩。
  abstract bestOf(accountId: string, challengeIds: string[]): Promise<Map<string, number>>;
  // 锁住并读这个挑战的最好成绩（结算用，没有为 0），再按需写入新的。
  abstract lockBest(manager: EntityManager, accountId: string, challengeId: string): Promise<number>;
  abstract saveBest(manager: EntityManager, best: { accountId: string; challengeId: string; points: number; runId: string; endsAt: Date }, now: Date): Promise<void>;
  // 到点还没结算的局（最多 limit 个），走 (active, deadline) 索引。
  abstract dueRuns(now: Date, limit: number): Promise<string[]>;
  abstract deleteRunsBefore(before: Date, limit: number): Promise<number>;
  abstract deleteBestBefore(before: Date, limit: number): Promise<number>;
  abstract deleteAccounts(manager: EntityManager, accountIds: string[]): Promise<void>;
}

type RawRun = Omit<RunRow, 'active'> & { active: number | null };

const columns = 'run_id AS runId, account_id AS accountId, challenge_id AS challengeId, active, deadline, plan, progress, ending, points, awarded, end_time AS endTime';

@Injectable()
export class TypeormChallengeRepository extends ChallengeRepository {
  constructor(@InjectRepository(ChallengeRunEntity) private readonly runs: Repository<ChallengeRunEntity>) {
    super();
  }

  async insertRun(run: RunRow, now: Date) {
    const inserted = (await this.runs.query(
      'INSERT IGNORE INTO challenge_run (run_id, account_id, challenge_id, active, deadline, plan, progress, ending, points, awarded, end_time, create_time, update_time) VALUES (?, ?, ?, 1, ?, ?, ?, NULL, NULL, NULL, NULL, ?, ?)',
      [run.runId, run.accountId, run.challengeId, run.deadline, run.plan, run.progress, now, now],
    )) as { affectedRows: number };
    return inserted.affectedRows === 1;
  }

  async activeRunOf(accountId: string) {
    const rows = (await this.runs.query('SELECT run_id AS runId FROM challenge_run WHERE account_id = ? AND active = 1', [accountId])) as { runId: string }[];
    return rows[0]?.runId ?? null;
  }

  withRun<T>(runId: string, accountId: string | null, work: (manager: EntityManager, run: RunRow | null) => Promise<T>) {
    return this.runs.manager.transaction(async (manager) => {
      const rows = (await manager.query(`SELECT ${columns} FROM challenge_run WHERE run_id = ? FOR UPDATE`, [runId])) as RawRun[];
      const row = rows[0];
      if (row === undefined || (accountId !== null && row.accountId !== accountId)) return work(manager, null);
      return work(manager, { ...row, active: row.active === 1 });
    });
  }

  async updateRun(manager: EntityManager, runId: string, changes: RunChanges, now: Date) {
    await manager.query(
      `UPDATE challenge_run SET progress = ?, ending = COALESCE(?, ending), points = COALESCE(?, points), awarded = COALESCE(?, awarded), end_time = COALESCE(?, end_time)${changes.settle === true ? ', active = NULL' : ''}, update_time = ? WHERE run_id = ?`,
      [changes.progress, changes.ending ?? null, changes.points ?? null, changes.awarded ?? null, changes.endTime ?? null, now, runId],
    );
  }

  async bestOf(accountId: string, challengeIds: string[]) {
    if (challengeIds.length === 0) return new Map<string, number>();
    const rows = (await this.runs.query('SELECT challenge_id AS challengeId, points FROM challenge_best WHERE account_id = ? AND challenge_id IN (?)', [accountId, challengeIds])) as { challengeId: string; points: number }[];
    return new Map(rows.map((row) => [row.challengeId, Number(row.points)]));
  }

  async lockBest(manager: EntityManager, accountId: string, challengeId: string) {
    const rows = (await manager.query('SELECT points FROM challenge_best WHERE account_id = ? AND challenge_id = ? FOR UPDATE', [accountId, challengeId])) as { points: number }[];
    return rows.length === 0 ? 0 : Number(rows[0].points);
  }

  async saveBest(manager: EntityManager, best: { accountId: string; challengeId: string; points: number; runId: string; endsAt: Date }, now: Date) {
    await manager.query(
      'INSERT INTO challenge_best (account_id, challenge_id, points, run_id, ends_at, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE points = VALUES(points), run_id = VALUES(run_id), update_time = VALUES(update_time)',
      [best.accountId, best.challengeId, best.points, best.runId, best.endsAt, now, now],
    );
  }

  async dueRuns(now: Date, limit: number) {
    const rows = (await this.runs.query('SELECT run_id AS runId FROM challenge_run WHERE active = 1 AND deadline <= ? ORDER BY deadline LIMIT ?', [now, limit])) as { runId: string }[];
    return rows.map((row) => row.runId);
  }

  async deleteRunsBefore(before: Date, limit: number) {
    const result = (await this.runs.query('DELETE FROM challenge_run WHERE active IS NULL AND end_time < ? ORDER BY end_time LIMIT ?', [before, limit])) as { affectedRows: number };
    return result.affectedRows;
  }

  async deleteBestBefore(before: Date, limit: number) {
    const result = (await this.runs.query('DELETE FROM challenge_best WHERE ends_at < ? ORDER BY ends_at LIMIT ?', [before, limit])) as { affectedRows: number };
    return result.affectedRows;
  }

  async deleteAccounts(manager: EntityManager, accountIds: string[]) {
    if (accountIds.length === 0) return;
    await manager.query('DELETE FROM challenge_run WHERE account_id IN (?)', [accountIds]);
    await manager.query('DELETE FROM challenge_best WHERE account_id IN (?)', [accountIds]);
  }
}
