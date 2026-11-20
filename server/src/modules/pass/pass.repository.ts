import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';

import { AccountPassEntity } from 'src/modules/pass/pass.entity';

// 时长券存储端口：服务只依赖这个抽象。
export abstract class PassRepository {
  // 这个账号还没到期的券（走 (account_id, pass_id) 唯一键，行数不超过券的种数）。
  abstract heldOf(accountId: string, now: Date): Promise<{ passId: string; expireTime: Date }[]>;
  // 在事务里续一张：锁住这一行，到期时刻 = max(现在, 原到期) + days，累计付的加 price，再在同一事务里调 charge（付积分），charge 抛错则整笔不留。返回新的到期时刻。
  abstract extend(accountId: string, passId: string, price: number, days: number, now: Date, charge: (manager: EntityManager, ref: string) => Promise<void>): Promise<Date>;
  // 删最多 limit 行在 before 之前就到期的，返回删的行数。
  abstract deleteExpired(before: Date, limit: number): Promise<number>;
  abstract deleteAccounts(manager: EntityManager, accountIds: string[]): Promise<void>;
}

@Injectable()
export class TypeormPassRepository extends PassRepository {
  constructor(@InjectRepository(AccountPassEntity) private readonly passes: Repository<AccountPassEntity>) {
    super();
  }

  async heldOf(accountId: string, now: Date) {
    const rows = (await this.passes.query('SELECT pass_id AS passId, expire_time AS expireTime FROM account_pass WHERE account_id = ? AND expire_time > ?', [accountId, now])) as { passId: string; expireTime: Date }[];
    return rows.map((row) => ({ passId: row.passId, expireTime: new Date(row.expireTime) }));
  }

  extend(accountId: string, passId: string, price: number, days: number, now: Date, charge: (manager: EntityManager, ref: string) => Promise<void>) {
    return this.passes.manager.transaction(async (manager) => {
      // 先占住这一行（没有就插一行已到期的），同一账号并发来两次排队，各扣各的、各续各的。
      await manager.query('INSERT IGNORE INTO account_pass (account_id, pass_id, expire_time, paid, create_time, update_time) VALUES (?, ?, ?, 0, ?, ?)', [accountId, passId, now, now, now]);
      const [row] = (await manager.query('SELECT id, expire_time AS expireTime FROM account_pass WHERE account_id = ? AND pass_id = ? FOR UPDATE', [accountId, passId])) as { id: number | string; expireTime: Date }[];
      const from = Math.max(now.getTime(), new Date(row.expireTime).getTime());
      const expire = new Date(from + days * 86400_000);
      await manager.query('UPDATE account_pass SET expire_time = ?, paid = paid + ?, update_time = ? WHERE id = ?', [expire, price, now, row.id]);
      await charge(manager, `pass:${row.id}:${expire.getTime()}`);
      return expire;
    });
  }

  async deleteExpired(before: Date, limit: number) {
    const result = (await this.passes.query('DELETE FROM account_pass WHERE expire_time < ? ORDER BY expire_time LIMIT ?', [before, limit])) as { affectedRows: number };
    return result.affectedRows;
  }

  async deleteAccounts(manager: EntityManager, accountIds: string[]) {
    if (accountIds.length === 0) return;
    await manager.query('DELETE FROM account_pass WHERE account_id IN (?)', [accountIds]);
  }
}
