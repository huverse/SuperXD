import { ChallengePeriod } from 'src/modules/challenge/challenge_calendar';

// 挑战配置（人工决策见客户端 lib/playground/challenge/challenge_rules.dart）：模板（关卡图、档位、限时）、轮换、限时活动与计分参数
// 都写在发布目录的 challenge/config.json（仓库 challenge/config.json 经流水线上传），按修改时间热加载，改了不用发版也不用重启；
// 写坏了不替换，接着用上一份并记错误日志。这里只做结构校验，题库够不够出某个模板由开局时的出题检查。

export const challengeTiers = ['entry', 'easy', 'normal', 'hard', 'expert'] as const;
export type ChallengeTier = (typeof challengeTiers)[number];

// 能收钥匙的游戏（同客户端 challengeConsumers）。
export const consumerGames = new Set(['twentyfour', 'queens', 'loop']);

export type ChallengeScoring = {
  // 每关基础分 = levelBase × 难度分（1–10）。
  levelBase: number;
  // 时间系数最低留这么多（用时是参考用时的几倍都不低于它）。
  timeFloor: number;
  // 每错交一次（含记忆闪光一题里点错）乘一次。
  errorDecay: number;
  // 按难度加权的过关率占多少：合计 ×（1 − passWeight + passWeight × 过关率）。
  passWeight: number;
  // 串联深度加成：第 k 层（从源头数）的关 ×（1 + depthBonus × k）。
  depthBonus: number;
  // 全部过关的奖励，与剩余时间奖励（按剩余时间占限时的比例，最多 timeBonus）。
  clearBonus: number;
  timeBonus: number;
  // 一关错交到这么多次就算没过（依赖它的关也就开不了）。
  maxErrors: number;
};

export type ChallengeNode = { id: string; tier: ChallengeTier; games: string[] | null };
export type ChallengeTemplate = { id: string; title: string; label: string; timeLimit: number; nodes: ChallengeNode[]; edges: [string, string][] };
export type ChallengeRotation = { id: string; every: ChallengePeriod; templates: string[] };
export type ChallengeEvent = { id: string; title: string; template: string; start: number; end: number };
export type ChallengeConfig = { scoring: ChallengeScoring; templates: Map<string, ChallengeTemplate>; rotations: ChallengeRotation[]; events: ChallengeEvent[] };

export class ChallengeConfigError extends Error {}

const fail = (message: string): never => {
  throw new ChallengeConfigError(message);
};

const record = (value: unknown, where: string) => (typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : fail(`${where} 要是对象`));
const list = (value: unknown, where: string, max: number) => (Array.isArray(value) && value.length <= max ? value : fail(`${where} 要是不超过 ${max} 项的列表`));
const text = (value: unknown, where: string, pattern: RegExp) => (typeof value === 'string' && pattern.test(value) ? value : fail(`${where} 不合法`));
const number = (value: unknown, where: string, min: number, max: number) => (typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max ? value : fail(`${where} 要在 ${min}–${max}`));
const idPattern = /^[a-z][a-z0-9_]{0,23}$/;
const titlePattern = /^\S(?:.{0,18}\S)?$/u;

const scoringOf = (raw: unknown): ChallengeScoring => {
  const value = record(raw, 'scoring');
  return {
    levelBase: number(value.levelBase, 'scoring.levelBase', 1, 1000),
    timeFloor: number(value.timeFloor, 'scoring.timeFloor', 0, 1),
    errorDecay: number(value.errorDecay, 'scoring.errorDecay', 0, 1),
    passWeight: number(value.passWeight, 'scoring.passWeight', 0, 1),
    depthBonus: number(value.depthBonus, 'scoring.depthBonus', 0, 1),
    clearBonus: number(value.clearBonus, 'scoring.clearBonus', 0, 5),
    timeBonus: number(value.timeBonus, 'scoring.timeBonus', 0, 5),
    maxErrors: Math.trunc(number(value.maxErrors, 'scoring.maxErrors', 1, 100)),
  };
};

// 关卡图：节点 id 唯一；每条边从给钥匙的关指向收钥匙的关；收钥匙的关只能是能收钥匙的游戏；每关最多给一把钥匙（最多一条出边）；不能有环；最多 maxLevels 关。
const templateOf = (id: string, raw: unknown, judged: Set<string>, maxLevels: number): ChallengeTemplate => {
  const value = record(raw, `模板 ${id}`);
  const nodes = list(value.nodes, `模板 ${id} 的 nodes`, maxLevels).map((item, index): ChallengeNode => {
    const node = record(item, `模板 ${id} 第 ${index + 1} 关`);
    const tier = text(node.tier, `模板 ${id} 的档位`, /^(entry|easy|normal|hard|expert)$/) as ChallengeTier;
    const games = node.games === undefined ? null : list(node.games, `模板 ${id} 的 games`, 32).map((game) => (typeof game === 'string' && judged.has(game) ? game : fail(`模板 ${id} 里的游戏 ${String(game)} 进不了挑战`)));
    if (games !== null && games.length === 0) fail(`模板 ${id} 的 games 不能为空`);
    return { id: text(node.id, `模板 ${id} 的关卡 id`, /^[a-z]{1,2}$/), tier, games };
  });
  if (nodes.length < 2) fail(`模板 ${id} 至少两关`);
  const ids = new Set(nodes.map((node) => node.id));
  if (ids.size !== nodes.length) fail(`模板 ${id} 的关卡 id 重复`);
  const edges = list(value.edges, `模板 ${id} 的 edges`, maxLevels).map((item): [string, string] => {
    const edge = list(item, `模板 ${id} 的边`, 2);
    const [from, to] = [String(edge[0]), String(edge[1])];
    if (edge.length !== 2 || !ids.has(from) || !ids.has(to) || from === to) fail(`模板 ${id} 的边 ${JSON.stringify(item)} 不合法`);
    return [from, to];
  });
  const outgoing = new Map<string, string>();
  for (const [from, to] of edges) {
    if (outgoing.has(from)) fail(`模板 ${id} 的 ${from} 不止一条出边`);
    outgoing.set(from, to);
  }
  for (const node of nodes) {
    if (!edges.some(([, to]) => to === node.id)) continue;
    if ((node.games ?? [...consumerGames]).some((game) => !consumerGames.has(game))) fail(`模板 ${id} 的 ${node.id} 收钥匙，只能是 ${[...consumerGames].join('、')}`);
  }
  // 每关只有一条出边，沿出边走不回原处就没有环。
  for (const node of nodes) {
    const seen = new Set<string>();
    for (let current: string | undefined = node.id; current !== undefined; current = outgoing.get(current)) {
      if (seen.has(current)) fail(`模板 ${id} 有环`);
      seen.add(current);
    }
  }
  return {
    id,
    title: text(value.title, `模板 ${id} 的 title`, titlePattern),
    label: text(value.label, `模板 ${id} 的 label`, titlePattern),
    timeLimit: Math.trunc(number(value.timeLimit, `模板 ${id} 的 timeLimit`, 60, 4 * 3600)),
    nodes,
    edges,
  };
};

export const parseChallengeConfig = (raw: unknown, judged: Set<string>, maxLevels: number): ChallengeConfig => {
  const value = record(raw, '配置');
  if (value.version !== 1) fail('配置的 version 要是 1');
  const templates = new Map(Object.entries(record(value.templates, 'templates')).map(([id, item]) => [text(id, '模板 id', idPattern), templateOf(id, item, judged, maxLevels)]));
  const rotations = list(value.rotations ?? [], 'rotations', 16).map((item): ChallengeRotation => {
    const rotation = record(item, '轮换');
    const names = list(rotation.templates, '轮换的 templates', 8).map((name) => (typeof name === 'string' && templates.has(name) ? name : fail(`轮换用了不存在的模板 ${String(name)}`)));
    return { id: text(rotation.id, '轮换 id', idPattern), every: text(rotation.every, '轮换的 every', /^(day|week)$/) as ChallengePeriod, templates: names };
  });
  const events = list(value.events ?? [], 'events', 64).map((item): ChallengeEvent => {
    const event = record(item, '活动');
    const start = Date.parse(text(event.start, '活动的 start', /^\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d)?([+-]\d\d:\d\d|Z)$/));
    const end = Date.parse(text(event.end, '活动的 end', /^\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d)?([+-]\d\d:\d\d|Z)$/));
    if (!(end > start)) fail('活动的 end 要晚于 start');
    const template = text(event.template, '活动的 template', idPattern);
    if (!templates.has(template)) fail(`活动用了不存在的模板 ${template}`);
    return { id: text(event.id, '活动 id', idPattern), title: text(event.title, '活动的 title', titlePattern), template, start, end };
  });
  const ids = [...rotations.map((rotation) => rotation.id), ...events.map((event) => event.id)];
  if (new Set(ids).size !== ids.length) fail('轮换与活动的 id 重复');
  return { scoring: scoringOf(value.scoring), templates, rotations, events };
};
