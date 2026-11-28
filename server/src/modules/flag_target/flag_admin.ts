import type Redis from 'ioredis';
import type { Connection } from 'mysql2/promise';

import { RedisKeys, RedisKeyTTL } from 'src/common/redis/redis_keys';

// 灰度点名的维护命令（规则见 flag_target.service.ts；命令行入口 src/tools/flag_admin.ts），在服务器上进中转容器执行，按用户名认人：
//   docker compose exec -T relay node dist/tools/flag_admin.js grant <开关> <用户名> [--until 2026-12-01T00:00+08:00]   点名（已点过就改到期时刻；不写 --until 是一直开到撤销）
//   docker compose exec -T relay node dist/tools/flag_admin.js revoke <开关> <用户名>                                      撤销
//   docker compose exec -T relay node dist/tools/flag_admin.js list [<开关>]                                                 列出（最多 500 条，按开关与用户名排）
// 开关编号同灰度配置的 id（客户端 lib/domain/feature_flags.dart 登记）；点名与撤销顺带通知这个账号的设备（见 bump），手机下一次联网或回到前台就生效；到期由手机按时刻自己判。
const flagPattern = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const listLimit = 500;

// 输入不对：命令行只打印这句话、不打印堆栈。
export class FlagAdminError extends Error {}

const fail = (message: string): never => {
  throw new FlagAdminError(message);
};

const untilOf = (args: string[]): Date | null => {
  const index = args.indexOf('--until');
  if (index < 0) return null;
  const value = args[index + 1];
  if (value === undefined || !/(Z|[+-]\d{2}:\d{2})$/.test(value)) fail('--until 要写带时区的时刻，如 2026-12-01T00:00+08:00');
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) fail(`--until 不是合法时刻：${value}`);
  return parsed;
};

const accountOf = async (connection: Connection, username: string) => {
  const [rows] = (await connection.query('SELECT account_id AS accountId FROM app_account WHERE username = ?', [username.toLowerCase()])) as unknown as [{ accountId: string }[]];
  return rows[0]?.accountId ?? fail(`没有用户名 ${username}`);
};

export const runFlagAdmin = async (connection: Connection, redis: Redis, args: string[], now = new Date()): Promise<string> => {
  const [command, flag, username, ...rest] = args;
  if (command === 'list') {
    if (flag !== undefined && !flagPattern.test(flag)) fail(`开关编号不合法：${flag}`);
    const [rows] = (await connection.query(
      `SELECT t.flag_id AS flagId, a.username, t.expires_at AS expiresAt FROM rollout_target t JOIN app_account a ON a.account_id = t.account_id ${flag === undefined ? '' : 'WHERE t.flag_id = ?'} ORDER BY t.flag_id, a.username LIMIT ${listLimit}`,
      flag === undefined ? [] : [flag],
    )) as unknown as [{ flagId: string; username: string; expiresAt: Date | null }[]];
    return rows.length === 0 ? '没有点名' : rows.map((row) => `${row.flagId}\t${row.username}\t${row.expiresAt === null ? '一直开' : new Date(row.expiresAt).toISOString()}`).join('\n');
  }
  if ((command !== 'grant' && command !== 'revoke') || flag === undefined || username === undefined) fail('用法见 src/modules/flag_target/flag_admin.ts 文件头');
  if (!flagPattern.test(flag)) fail(`开关编号不合法：${flag}`);
  const accountId = await accountOf(connection, username);
  if (command === 'revoke') {
    const [result] = (await connection.query('DELETE FROM rollout_target WHERE flag_id = ? AND account_id = ?', [flag, accountId])) as unknown as [{ affectedRows: number }];
    if (result.affectedRows === 0) return `${username} 没有被点名 ${flag}`;
    return `已撤销 ${username} 的 ${flag}${await bump(connection, redis, accountId, now)}`;
  }
  const until = untilOf(rest);
  if (until !== null && until <= now) fail('--until 要晚于现在');
  // 同各模块的写入门禁（account.repository.ts 的 holdIn）：同一事务里先给账号行加共享锁、确认还在再写，查到之后才注销的账号不留点名（11-28 复核 F05）。
  await connection.beginTransaction();
  try {
    const [held] = (await connection.query('SELECT account_id FROM app_account WHERE account_id = ? FOR SHARE', [accountId])) as unknown as [unknown[]];
    if (held.length === 0) fail(`没有用户名 ${username}`);
    await connection.query(
      'INSERT INTO rollout_target (flag_id, account_id, expires_at, create_time, update_time) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE expires_at = VALUES(expires_at), update_time = VALUES(update_time)',
      [flag, accountId, until, now, now],
    );
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }
  return `已点名 ${username} 的 ${flag}（${until === null ? '一直开到撤销' : `到 ${until.toISOString()}`}）${await bump(connection, redis, accountId, now)}`;
};

// 点名变了就给这个账号下的每台设备写新的点名版本（人工决策见 src/modules/app_release/config_revision.ts）：应用账号的设备密钥（最多 accountDeviceLimit 把）
// 加挂着的私信设备（私信长轮询一直连着，用它的手机几十秒内就看到）；手机下一次签名请求在回复头里读到，马上重新问点名。
const bump = async (connection: Connection, redis: Redis, accountId: string, now: Date) => {
  const [keys] = (await connection.query('SELECT device_id AS deviceId FROM account_device WHERE account_id = ?', [accountId])) as unknown as [{ deviceId: string }[]];
  const [social] = (await connection.query('SELECT device_id AS deviceId FROM account_social WHERE account_id = ?', [accountId])) as unknown as [{ deviceId: string }[]];
  const devices = [...new Set([...keys, ...social].map((row) => row.deviceId))];
  if (devices.length === 0) return '';
  const pipeline = redis.pipeline();
  for (const deviceId of devices) pipeline.set(RedisKeys.flagTargetsRevision(deviceId), String(now.getTime()), 'EX', RedisKeyTTL.flagTargetsRevision);
  for (const [error] of (await pipeline.exec()) ?? []) if (error !== null) throw error;
  return `，已通知 ${devices.length} 台设备`;
};
