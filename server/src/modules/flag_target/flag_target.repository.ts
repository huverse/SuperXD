import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';

import { RolloutTargetEntity } from 'src/modules/flag_target/flag_target.entity';

export type FlagTarget = { flagId: string; expiresAt: Date | null };

// 灰度点名的存储端口：服务只依赖这个抽象。
export abstract class FlagTargetRepository {
  // 这个账号此刻被点名的开关（没过期的，走 idx_account_expires；最多 limit 个）。
  abstract activeOf(accountId: string, now: Date, limit: number): Promise<FlagTarget[]>;
  // 删最多 limit 行过期的，返回删的行数。
  abstract deleteExpired(now: Date, limit: number): Promise<number>;
  abstract deleteAccounts(manager: EntityManager, accountIds: string[]): Promise<void>;
}

@Injectable()
export class TypeormFlagTargetRepository extends FlagTargetRepository {
  constructor(@InjectRepository(RolloutTargetEntity) private readonly targets: Repository<RolloutTargetEntity>) {
    super();
  }

  async activeOf(accountId: string, now: Date, limit: number) {
    const rows = (await this.targets.query(
      'SELECT flag_id AS flagId, expires_at AS expiresAt FROM rollout_target WHERE account_id = ? AND (expires_at IS NULL OR expires_at > ?) ORDER BY flag_id LIMIT ?',
      [accountId, now, limit],
    )) as { flagId: string; expiresAt: Date | null }[];
    return rows.map((row) => ({ flagId: row.flagId, expiresAt: row.expiresAt === null ? null : new Date(row.expiresAt) }));
  }

  async deleteExpired(now: Date, limit: number) {
    const result = (await this.targets.query('DELETE FROM rollout_target WHERE expires_at IS NOT NULL AND expires_at <= ? LIMIT ?', [now, limit])) as { affectedRows: number };
    return result.affectedRows;
  }

  async deleteAccounts(manager: EntityManager, accountIds: string[]) {
    if (accountIds.length === 0) return;
    await manager.query('DELETE FROM rollout_target WHERE account_id IN (?)', [accountIds]);
  }
}
