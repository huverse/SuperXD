import type { Connection } from 'mysql2/promise';

import { pointsLevelCount, rewardAudienceImportMax, rewardDefaultMinAccountDays, rewardMinAccountDaysMax } from 'src/common/relay_limits';
import { rewardAudiences, RewardAudience, rewardDistributions, RewardDistribution, rewardModes, RewardMode } from 'src/modules/reward/reward_odds';

// 节日抽奖的维护命令（概率模型见 src/modules/reward/reward_odds.ts；命令行入口 src/tools/reward_admin.ts），在服务器上进中转容器执行，奖品只经标准输入进库、不落地成文件：
//   docker compose exec -T relay node dist/tools/reward_admin.js create <编号> --from 2027-02-06T00:00+08:00 --to 2027-02-07T00:00+08:00 --mode weighted --chance 0.2 --max-weight 3
//   docker compose exec -T relay node dist/tools/reward_admin.js import <编号> [--tier 1] < 奖品.tsv     每行「口令<TAB>内容」或「二维码<TAB>内容」，可再加「<TAB>附言」；
//     --tier 是这批奖品的金额档（0 普通，默认；数越大金额越高，抽中后大额档按等级加权挑，规则见 reward_odds.ts），不同档分批导入
//   docker compose exec -T relay node dist/tools/reward_admin.js status <编号>
//   资格与发放（人工决策见 reward_odds.ts 的 11-16 那条），create 另可写：--distribution lottery|all（默认 lottery 抽签；all 有资格就发，不用写 --chance 与 --mode）、
//     --audience everyone|list（默认 everyone；list 只有名单里的人）、--min-account-days 0–3650（默认 7）、--min-level 0–5（默认 0）
//   docker compose exec -T relay node dist/tools/reward_admin.js audience <编号> < 名单.txt   每行一个应用账号用户名（不分大小写），导入名单（已在的不重复记），
//     报出对不上的用户名；故障补偿把受影响的人导进来
// 编号与客户端节日登记的 campaign、或开发者的话里附件的 ref 一致；create 对已有的编号是改设置（开始后改时长会改变放量节奏，慎改）。平权时 --max-weight 不用写。
const kinds: Record<string, 'password' | 'qrcode'> = { 口令: 'password', 二维码: 'qrcode' };
const importChunk = 1000;
const tierMax = 9;

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

// 执行一条维护命令，返回要打印的结果；lines 现取标准输入的各行，只有 import 调用。
// 要读时才取、取完立刻逐行读：readline 在开始迭代之前发出的行会丢（先查库再读，小文件的行连同结束一起丢光、一直等下去），
// 不读输入的命令也不能先建 readline（进程会等标准输入结束、不退出）。
export const runRewardAdmin = async (connection: Connection, args: string[], lines: () => AsyncIterable<string>): Promise<string> => {
  const [command, key, ...rest] = args;
  if (command === undefined || key === undefined || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(key)) fail('用法见 src/tools/reward_admin.ts 文件头');
  if (command === 'create') {
    const from = instant(option(rest, 'from'), 'from'), to = instant(option(rest, 'to'), 'to');
    const distribution = (option(rest, 'distribution') ?? 'lottery') as RewardDistribution;
    const audience = (option(rest, 'audience') ?? 'everyone') as RewardAudience;
    const minAccountDays = Number(option(rest, 'min-account-days') ?? rewardDefaultMinAccountDays), minLevel = Number(option(rest, 'min-level') ?? '0');
    if (!rewardDistributions.includes(distribution)) fail(`--distribution 只能是 ${rewardDistributions.join(' 或 ')}`);
    if (!rewardAudiences.includes(audience)) fail(`--audience 只能是 ${rewardAudiences.join(' 或 ')}`);
    if (!Number.isInteger(minAccountDays) || minAccountDays < 0 || minAccountDays > rewardMinAccountDaysMax) fail(`--min-account-days 是 0 到 ${rewardMinAccountDaysMax} 的整数`);
    if (!Number.isInteger(minLevel) || minLevel < 0 || minLevel >= pointsLevelCount) fail(`--min-level 是 0 到 ${pointsLevelCount - 1} 的整数`);
    // all 不抽签：概率记 1，模式只用来按等级挑金额档（默认平权）。
    const mode = (option(rest, 'mode') ?? (distribution === 'all' ? 'uniform' : undefined)) as RewardMode;
    const chance = distribution === 'all' ? 1 : Number(option(rest, 'chance')), maxWeight = mode === 'uniform' ? 1 : Number(option(rest, 'max-weight'));
    if (to <= from) fail('--to 要晚于 --from');
    if (!rewardModes.includes(mode)) fail(`--mode 只能是 ${rewardModes.join(' 或 ')}`);
    if (!(chance > 0 && chance <= 1)) fail('--chance 是权重为 1 的人抽中的概率，0 到 1 之间');
    if (!(maxWeight >= 1 && maxWeight <= 10)) fail('--max-weight 是加权上限，1 到 10 之间');
    const now = new Date();
    await connection.query(
      'INSERT INTO reward_campaign (campaign_key, starts_at, ends_at, mode, base_chance, max_weight, distribution, audience, min_account_days, min_level, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ' +
        'ON DUPLICATE KEY UPDATE starts_at = VALUES(starts_at), ends_at = VALUES(ends_at), mode = VALUES(mode), base_chance = VALUES(base_chance), max_weight = VALUES(max_weight), ' +
        'distribution = VALUES(distribution), audience = VALUES(audience), min_account_days = VALUES(min_account_days), min_level = VALUES(min_level), update_time = VALUES(update_time)',
      [key, from, to, mode, chance.toFixed(6), maxWeight.toFixed(2), distribution, audience, minAccountDays, minLevel, now, now],
    );
    return `[RewardAdmin] action=create campaign=${key} from=${from.toISOString()} to=${to.toISOString()} distribution=${distribution} audience=${audience} minAccountDays=${minAccountDays} minLevel=${minLevel} mode=${mode} chance=${chance} maxWeight=${maxWeight}`;
  }
  const [[campaign]] = (await connection.query(
    'SELECT id, starts_at AS startsAt, ends_at AS endsAt, mode, base_chance AS baseChance, max_weight AS maxWeight, distribution, audience, min_account_days AS minAccountDays, min_level AS minLevel FROM reward_campaign WHERE campaign_key = ?',
    [key],
  )) as unknown as [{ id: string; startsAt: Date; endsAt: Date; mode: string; baseChance: string; maxWeight: string; distribution: string; audience: string; minAccountDays: number; minLevel: number }[]];
  if (campaign === undefined) fail(`没有活动 ${key}，先 create`);
  if (command === 'import') {
    const tier = Number(option(rest, 'tier') ?? '0');
    if (!Number.isInteger(tier) || tier < 0 || tier > tierMax) fail(`--tier 是金额档，0 到 ${tierMax} 的整数`);
    // 边读边按 importChunk 份一批写，整个导入一个事务（11-28 审查 F07：原来先把全部行读进内存再写）：哪一行不对整批都不进库；
    // 这一档的库存计数 reward_tier_stock 在同一事务里加上（抽中时只读计数）。
    const now = new Date();
    let line = 0, total = 0;
    let chunk: [string, number, string, string, string, Date, Date][] = [];
    const flush = async () => {
      if (chunk.length === 0) return;
      await connection.query('INSERT INTO reward_prize (campaign_id, tier, kind, content, note, create_time, update_time) VALUES ?', [chunk]);
      total += chunk.length;
      chunk = [];
    };
    await connection.beginTransaction();
    try {
      for await (const text of lines()) {
        line++;
        if (text.trim() === '') continue;
        const [label, content = '', note = ''] = text.replace(/^\uFEFF/, '').split('\t').map((part) => part.trim());
        const kind = kinds[label];
        if (kind === undefined) fail(`第 ${line} 行：开头写「口令」或「二维码」，再用 Tab 隔开内容`);
        if (content === '' || content.length > 1024) fail(`第 ${line} 行：内容为空或超过 1024 字`);
        if (note.length > 200) fail(`第 ${line} 行：附言超过 200 字`);
        chunk.push([campaign.id, tier, kind, content, note, now, now]);
        if (chunk.length >= importChunk) await flush();
      }
      await flush();
      if (total === 0) fail('没有读到奖品');
      await connection.query(
        'INSERT INTO reward_tier_stock (campaign_id, tier, stock, given, create_time, update_time) VALUES (?, ?, ?, 0, ?, ?) ON DUPLICATE KEY UPDATE stock = stock + VALUES(stock), update_time = VALUES(update_time)',
        [campaign.id, tier, total, now, now],
      );
      await connection.commit();
    } catch (error) {
      await connection.rollback();
      throw error;
    }
    return `[RewardAdmin] action=import campaign=${key} tier=${tier} prizes=${total}`;
  }
  if (command === 'audience') {
    // 先读完再查库（见上面 lines 的说明）；按 1000 个一批换成账号号、批量写入，不逐个查。
    const names = new Set<string>();
    for await (const text of lines()) {
      const name = text.replace(/^\uFEFF/, '').trim().toLowerCase();
      if (name === '') continue;
      if (!/^[a-z0-9_]{3,20}$/.test(name)) fail(`用户名不合法：${name}`);
      names.add(name);
      if (names.size > rewardAudienceImportMax) fail(`一次最多导入 ${rewardAudienceImportMax} 个用户名`);
    }
    if (names.size === 0) fail('没有读到用户名');
    const all = [...names], found = new Set<string>();
    const now = new Date();
    let added = 0;
    for (let start = 0; start < all.length; start += importChunk) {
      const [rows] = (await connection.query('SELECT account_id AS accountId, username FROM app_account WHERE username IN (?)', [all.slice(start, start + importChunk)])) as unknown as [{ accountId: string; username: string }[]];
      for (const row of rows) found.add(row.username);
      if (rows.length === 0) continue;
      const [result] = (await connection.query('INSERT IGNORE INTO reward_audience (campaign_id, account_id, create_time, update_time) VALUES ?', [rows.map((row) => [campaign.id, row.accountId, now, now])])) as unknown as [
        { affectedRows: number },
      ];
      added += result.affectedRows;
    }
    const missing = all.filter((name) => !found.has(name));
    return `[RewardAdmin] action=audience campaign=${key} names=${all.length} added=${added} unknown=${missing.length}` + (missing.length === 0 ? '' : `\n对不上的用户名：${missing.slice(0, 50).join('、')}${missing.length > 50 ? ' 等' : ''}`);
  }
  if (command === 'status') {
    const [tiers] = (await connection.query('SELECT tier, COUNT(*) AS stock, COUNT(draw_id) AS given FROM reward_prize WHERE campaign_id = ? GROUP BY tier ORDER BY tier', [campaign.id])) as unknown as [
      { tier: number; stock: number; given: number }[],
    ];
    const prizes = { stock: tiers.reduce((sum, row) => sum + Number(row.stock), 0), given: tiers.reduce((sum, row) => sum + Number(row.given), 0) };
    const [[{ audience }]] = (await connection.query('SELECT COUNT(*) AS audience FROM reward_audience WHERE campaign_id = ?', [campaign.id])) as unknown as [{ audience: number }[]];
    const [[draws]] = (await connection.query('SELECT COUNT(*) AS draws, COUNT(prize_id) AS winners, AVG(active_days) AS activeDays FROM reward_draw WHERE campaign_id = ?', [campaign.id])) as unknown as [
      { draws: number; winners: number; activeDays: string | null }[],
    ];
    return (
      `活动 ${key}：${campaign.startsAt.toISOString()} 到 ${campaign.endsAt.toISOString()}，模式 ${campaign.mode}，基础概率 ${campaign.baseChance}，加权上限 ${campaign.maxWeight}\n` +
      `发放 ${campaign.distribution}，资格 ${campaign.audience}${campaign.audience === 'list' ? `（名单 ${audience} 人）` : ''}，账号满 ${campaign.minAccountDays} 天，最低等级 ${campaign.minLevel}\n` +
      `奖品 ${prizes.stock} 份，已发 ${prizes.given} 份；抽签 ${draws.draws} 人，中 ${draws.winners} 人，平均活跃 ${Number(draws.activeDays ?? 0).toFixed(1)} 天` +
      (tiers.length > 1 ? `\n${tiers.map((row) => `第 ${row.tier} 档：${row.stock} 份，已发 ${row.given} 份`).join('；')}` : '')
    );
  }
  return fail(`不认识的命令 ${command}，只有 create、import、audience、status`);
};
