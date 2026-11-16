import type { Connection } from 'mysql2/promise';

// 灰度点名的维护命令（规则见 flag_target.service.ts；命令行入口 src/tools/flag_admin.ts），在服务器上进中转容器执行，按用户名认人：
//   docker compose exec -T relay node dist/tools/flag_admin.js grant <开关> <用户名> [--until 2026-12-01T00:00+08:00]   点名（已点过就改到期时刻；不写 --until 是一直开到撤销）
//   docker compose exec -T relay node dist/tools/flag_admin.js revoke <开关> <用户名>                                      撤销
//   docker compose exec -T relay node dist/tools/flag_admin.js list [<开关>]                                                 列出（最多 500 条，按开关与用户名排）
// 开关编号同灰度配置的 id（客户端 lib/domain/feature_flags.dart 登记）；手机隔一小时或回到前台时来问，撤销与到期在下一次问时生效。
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

export const runFlagAdmin = async (connection: Connection, args: string[], now = new Date()): Promise<string> => {
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
    return result.affectedRows === 0 ? `${username} 没有被点名 ${flag}` : `已撤销 ${username} 的 ${flag}`;
  }
  const until = untilOf(rest);
  if (until !== null && until <= now) fail('--until 要晚于现在');
  await connection.query(
    'INSERT INTO rollout_target (flag_id, account_id, expires_at, create_time, update_time) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE expires_at = VALUES(expires_at), update_time = VALUES(update_time)',
    [flag, accountId, until, now, now],
  );
  return `已点名 ${username} 的 ${flag}（${until === null ? '一直开到撤销' : `到 ${until.toISOString()}`}）`;
};
