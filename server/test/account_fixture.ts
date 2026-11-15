import { randomBytes } from 'node:crypto';
import { DataSource } from 'typeorm';

// 别的模块的测试直接往库里放一个应用账号（用户名随机、哈希是占位，测试不走登录）。
export const insertAccount = (database: DataSource, accountId: string, now: Date, created = now) =>
  database.query('INSERT INTO app_account (account_id, username, password_hash, recovery_hash, last_seen_time, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?)', [
    accountId,
    `t${randomBytes(9).toString('hex')}`,
    'placeholder',
    'placeholder',
    now,
    created,
    now,
  ]);
