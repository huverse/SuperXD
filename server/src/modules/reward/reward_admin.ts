import type { Connection } from 'mysql2/promise';

import { rewardModes, RewardMode } from 'src/modules/reward/reward_odds';

// 节日抽奖的维护命令（概率模型见 src/modules/reward/reward_odds.ts；命令行入口 src/tools/reward_admin.ts），在服务器上进中转容器执行，奖品只经标准输入进库、不落地成文件：
//   docker compose exec -T relay node dist/tools/reward_admin.js create <编号> --from 2027-02-06T00:00+08:00 --to 2027-02-07T00:00+08:00 --mode weighted --chance 0.2 --max-weight 3
//   docker compose exec -T relay node dist/tools/reward_admin.js import <编号> < 奖品.tsv     每行「口令<TAB>内容」或「二维码<TAB>内容」，可再加「<TAB>附言」
//   docker compose exec -T relay node dist/tools/reward_admin.js status <编号>
// 编号与客户端节日登记的 campaign 一致；create 对已有的编号是改设置（开始后改时长会改变放量节奏，慎改）。平权时 --max-weight 不用写。
const kinds: Record<string, 'password' | 'qrcode'> = { 口令: 'password', 二维码: 'qrcode' };
const importChunk = 1000;

// 输入不对：命令行只打印这句话、不打印堆栈。
export class RewardAdminError extends Error {}

const fail = (message: string): never => {
  throw new RewardAdminError(message);
};

const option = (args: string[], name: string): string | undefined => {
  const index = args.indexOf(`--${name}`);
  return index < 0 ? undefined : args[index + 1];
};

const instant = (value: string | undefined, name: string): Date => {
  if (value === undefined || !/(Z|[+-]\d{2}:\d{2})$/.test(value)) fail(`--${name} 要写带时区的时刻，如 2027-02-06T00:00+08:00`);
  const parsed = new Date(value!);
  if (Number.isNaN(parsed.getTime())) fail(`--${name} 不是合法时刻：${value}`);
  return parsed;
};

// 执行一条维护命令，返回要打印的结果；lines 是标准输入的各行（只有 import 用）。
export const runRewardAdmin = async (connection: Connection, args: string[], lines: AsyncIterable<string>): Promise<string> => {
  const [command, key, ...rest] = args;
  if (command === undefined || key === undefined || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(key)) fail('用法见 src/tools/reward_admin.ts 文件头');
  if (command === 'create') {
    const from = instant(option(rest, 'from'), 'from'), to = instant(option(rest, 'to'), 'to');
    const mode = option(rest, 'mode') as RewardMode;
    const chance = Number(option(rest, 'chance')), maxWeight = mode === 'uniform' ? 1 : Number(option(rest, 'max-weight'));
    if (to <= from) fail('--to 要晚于 --from');
    if (!rewardModes.includes(mode)) fail(`--mode 只能是 ${rewardModes.join(' 或 ')}`);
    if (!(chance > 0 && chance <= 1)) fail('--chance 是权重为 1 的人抽中的概率，0 到 1 之间');
    if (!(maxWeight >= 1 && maxWeight <= 10)) fail('--max-weight 是加权上限，1 到 10 之间');
    const now = new Date();
    await connection.query(
      'INSERT INTO reward_campaign (campaign_key, starts_at, ends_at, mode, base_chance, max_weight, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ' +
        'ON DUPLICATE KEY UPDATE starts_at = VALUES(starts_at), ends_at = VALUES(ends_at), mode = VALUES(mode), base_chance = VALUES(base_chance), max_weight = VALUES(max_weight), update_time = VALUES(update_time)',
      [key, from, to, mode, chance.toFixed(6), maxWeight.toFixed(2), now, now],
    );
    return `[RewardAdmin] action=create campaign=${key} from=${from.toISOString()} to=${to.toISOString()} mode=${mode} chance=${chance} maxWeight=${maxWeight}`;
  }
  const [[campaign]] = (await connection.query('SELECT id, starts_at AS startsAt, ends_at AS endsAt, mode, base_chance AS baseChance, max_weight AS maxWeight FROM reward_campaign WHERE campaign_key = ?', [key])) as unknown as [
    { id: string; startsAt: Date; endsAt: Date; mode: string; baseChance: string; maxWeight: string }[],
  ];
  if (campaign === undefined) fail(`没有活动 ${key}，先 create`);
  if (command === 'import') {
    const rows: [string, string, string, string, Date, Date][] = [];
    const now = new Date();
    let line = 0;
    for await (const text of lines) {
      line++;
      if (text.trim() === '') continue;
      const [label, content = '', note = ''] = text.replace(/^\uFEFF/, '').split('\t').map((part) => part.trim());
      const kind = kinds[label];
      if (kind === undefined) fail(`第 ${line} 行：开头写「口令」或「二维码」，再用 Tab 隔开内容`);
      if (content === '' || content.length > 1024) fail(`第 ${line} 行：内容为空或超过 1024 字`);
      if (note.length > 200) fail(`第 ${line} 行：附言超过 200 字`);
      rows.push([campaign.id, kind, content, note, now, now]);
    }
    if (rows.length === 0) fail('没有读到奖品');
    for (let start = 0; start < rows.length; start += importChunk) {
      await connection.query('INSERT INTO reward_prize (campaign_id, kind, content, note, create_time, update_time) VALUES ?', [rows.slice(start, start + importChunk)]);
    }
    return `[RewardAdmin] action=import campaign=${key} prizes=${rows.length}`;
  }
  if (command === 'status') {
    const [[prizes]] = (await connection.query('SELECT COUNT(*) AS stock, COUNT(draw_id) AS given FROM reward_prize WHERE campaign_id = ?', [campaign.id])) as unknown as [{ stock: number; given: number }[]];
    const [[draws]] = (await connection.query('SELECT COUNT(*) AS draws, COUNT(prize_id) AS winners, AVG(active_days) AS activeDays FROM reward_draw WHERE campaign_id = ?', [campaign.id])) as unknown as [
      { draws: number; winners: number; activeDays: string | null }[],
    ];
    return (
      `活动 ${key}：${campaign.startsAt.toISOString()} 到 ${campaign.endsAt.toISOString()}，模式 ${campaign.mode}，基础概率 ${campaign.baseChance}，加权上限 ${campaign.maxWeight}\n` +
      `奖品 ${prizes.stock} 份，已发 ${prizes.given} 份；抽签 ${draws.draws} 人，中 ${draws.winners} 人，平均活跃 ${Number(draws.activeDays ?? 0).toFixed(1)} 天`
    );
  }
  return fail(`不认识的命令 ${command}，只有 create、import、status`);
};
