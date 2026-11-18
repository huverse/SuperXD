import type { Connection } from 'mysql2/promise';

import { healthFrameTiers, healthLaunchTiers, tierColumns } from 'src/modules/app_health/app_health_rules';

// 分批更新的健康与意见的维护命令（规则见 app_health_rules.ts；命令行入口 src/tools/health_admin.ts），在服务器上进中转容器执行：
//   docker compose exec -T relay node dist/tools/health_admin.js status <渠道>                    最近 14 天各版本的回报份数与致命率、启动档与慢帧档的分布，以及暂停记录
//   docker compose exec -T relay node dist/tools/health_admin.js resume <渠道> <版本号>            解除自动暂停（之后不再自动停这一版）
//   docker compose exec -T relay node dist/tools/health_admin.js feedback <渠道> <版本号>          这一版的意见：好与不好的条数、最近 50 条的话
const channelPattern = /^[a-z][a-z0-9_-]{0,31}$/;

export class HealthAdminError extends Error {}

const fail = (message: string): never => {
  throw new HealthAdminError(message);
};

const versionOf = (value: string | undefined) => {
  const versionCode = Number(value);
  return Number.isInteger(versionCode) && versionCode > 0 ? versionCode : fail(`版本号不合法：${value}`);
};

export const runHealthAdmin = async (connection: Connection, args: string[], now = new Date()): Promise<string> => {
  const [command, channel, version] = args;
  if (command === undefined || channel === undefined || !channelPattern.test(channel)) fail('用法见 src/modules/app_health/health_admin.ts 文件头');
  if (command === 'status') {
    const since = new Date(now.getTime() - 14 * 86400_000).toISOString().slice(0, 10);
    const tiers = [...tierColumns('launch', healthLaunchTiers), ...tierColumns('frames', healthFrameTiers)];
    const [rows] = (await connection.query(
      `SELECT version_code AS versionCode, platform, SUM(reports) AS reports, SUM(fatal) AS fatal, ${tiers.map((column) => `SUM(${column}) AS ${column}`).join(', ')} FROM app_health_daily WHERE channel = ? AND day >= ? GROUP BY version_code, platform ORDER BY version_code DESC, platform LIMIT 40`,
      [channel, since],
    )) as unknown as [({ versionCode: number; platform: string; reports: string; fatal: string } & Record<string, string>)[]];
    const [pauses] = (await connection.query('SELECT version_code AS versionCode, paused, reason, create_time AS createdAt FROM app_release_pause WHERE channel = ? ORDER BY id DESC LIMIT 20', [channel])) as unknown as [
      { versionCode: number; paused: number; reason: string; createdAt: Date }[],
    ];
    // 档位分布：带了档位的份数为 0 的那一项不写（旧客户端不带）。
    const spread = (row: Record<string, string>, kind: 'launch' | 'frames', names: string[]) => {
      const counts = tierColumns(kind, names.length).map((column) => Number(row[column] ?? 0));
      return counts.some((count) => count > 0) ? names.map((name, tier) => `${name} ${counts[tier]}`).join(' · ') : null;
    };
    const lines = rows.map((row) => {
      const launch = spread(row, 'launch', ['<0.5s', '0.5–1s', '1–2s', '≥2s']), frames = spread(row, 'frames', ['<5%', '5–15%', '15–40%', '≥40%']);
      return [
        `${row.versionCode} ${row.platform}：${row.reports} 份，致命 ${row.fatal}（${((Number(row.fatal) / Number(row.reports)) * 100).toFixed(1)}%）`,
        ...(launch === null ? [] : [`启动 ${launch}`]),
        ...(frames === null ? [] : [`慢帧 ${frames}`]),
      ].join('；');
    });
    const paused = pauses.map((row) => `${row.versionCode} ${row.paused === 1 ? '停着' : '已解除'}：${row.reason}（${new Date(row.createdAt).toISOString()}）`);
    return [`渠道 ${channel} 近 14 天：`, ...(lines.length === 0 ? ['没有回报'] : lines), '暂停：', ...(paused.length === 0 ? ['没有'] : paused)].join('\n');
  }
  const versionCode = versionOf(version);
  if (command === 'resume') {
    const [result] = (await connection.query('UPDATE app_release_pause SET paused = 0, update_time = ? WHERE channel = ? AND version_code = ? AND paused = 1', [now, channel, versionCode])) as unknown as [{ affectedRows: number }];
    return result.affectedRows === 0 ? `${channel} ${versionCode} 没有停着` : `已解除 ${channel} ${versionCode} 的暂停`;
  }
  if (command === 'feedback') {
    const [[counts]] = (await connection.query('SELECT SUM(good = 1) AS good, SUM(good = 0) AS bad FROM app_feedback WHERE channel = ? AND version_code = ?', [channel, versionCode])) as unknown as [{ good: string | null; bad: string | null }[]];
    const [texts] = (await connection.query("SELECT good, text, create_time AS createdAt FROM app_feedback WHERE channel = ? AND version_code = ? AND text <> '' ORDER BY id DESC LIMIT 50", [channel, versionCode])) as unknown as [
      { good: number; text: string; createdAt: Date }[],
    ];
    return [`${channel} ${versionCode}：好 ${Number(counts.good ?? 0)} 条，不好 ${Number(counts.bad ?? 0)} 条`, ...texts.map((row) => `${row.good === 1 ? '好' : '不好'}\t${row.text}`)].join('\n');
  }
  return fail(`不认识的命令 ${command}，只有 status、resume、feedback`);
};
