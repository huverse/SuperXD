import { ChallengePlan } from 'src/modules/challenge/challenge_plan';

// 一局的进度与计分（纯函数，服务层在行锁里调用）。时刻一律是服务器的 UTC 毫秒，客户端的时间不参与。

export type LevelState = 'locked' | 'open' | 'solved' | 'failed';
export type LevelProgress = { state: LevelState; openedAt: number | null; solvedAt: number | null; errors: number; penalties: number; submissions: number };
export type RunProgress = { startedAt: number; levels: Record<string, LevelProgress> };

// 开局：不收钥匙的关直接开，其余锁着。
export const startProgress = (plan: ChallengePlan, now: number): RunProgress => ({
  startedAt: now,
  levels: Object.fromEntries(
    plan.levels.map((level) => [level.id, { state: level.inputs.length === 0 ? 'open' : 'locked', openedAt: level.inputs.length === 0 ? now : null, solvedAt: null, errors: 0, penalties: 0, submissions: 0 }]),
  ),
});

// 记一次判定（这一关必须开着）：解开就记过关时刻，收它钥匙的那关的钥匙都齐了就解锁；没解开计一次错交，到上限算没过。
export const recordVerdict = (plan: ChallengePlan, progress: RunProgress, levelId: string, solved: boolean, penalties: number, now: number) => {
  const level = plan.levels.find((item) => item.id === levelId)!;
  const state = progress.levels[levelId];
  state.submissions++;
  if (!solved) {
    state.errors++;
    if (state.errors >= plan.scoring.maxErrors) state.state = 'failed';
    return;
  }
  state.state = 'solved';
  state.solvedAt = now;
  state.penalties = penalties;
  if (level.output === null) return;
  const target = plan.levels.find((item) => item.id === level.output)!;
  if (target.inputs.every((input) => progress.levels[input].state === 'solved')) {
    progress.levels[target.id].state = 'open';
    progress.levels[target.id].openedAt = now;
  }
};

// 这一局还能不能接着做：全过了是 cleared；没有开着的关（剩下的都因为前面没过而开不了）是 stuck；否则 null。
export const runOutcome = (progress: RunProgress) => {
  const states = Object.values(progress.levels).map((level) => level.state);
  if (states.every((state) => state === 'solved')) return 'cleared';
  return states.includes('open') ? null : 'stuck';
};

export type RunScore = { points: number; passRate: number; cleared: boolean; levels: Record<string, number> };

// 计分（参数是开局时的配置快照，见 challenge_config.ts 的 ChallengeScoring）：
// - 每关基础分 levelBase × 难度分 d；参考用时 = 限时 × d ÷ 全部关的难度分之和；这一关的用时按分段算：从它解锁、或这一局上一次过关
//   （两者取晚的）起，到它过关（几关同时开着时人一次只做一关，分段用时就是花在它上面的时间，同竞速比赛的分段计时）。
// - 时间系数 = 参考用时 ÷ 用时，夹在 timeFloor 到 1 之间；每错交一次（含答案里自带的失误）乘一次 errorDecay；串联第 k 层再乘 1 + depthBonus × k。
// - 合计 ×（1 − passWeight + passWeight × 按难度加权的过关率）；全部过关再 ×（1 + clearBonus + timeBonus × 剩余时间 ÷ 限时）。取整。
export const scoreRun = (plan: ChallengePlan, progress: RunProgress, endAt: number): RunScore => {
  const { scoring } = plan;
  const total = plan.levels.reduce((sum, level) => sum + level.difficulty, 0);
  const solved = plan.levels.filter((level) => progress.levels[level.id].state === 'solved');
  const finishes = solved.map((level) => progress.levels[level.id].solvedAt!).sort((left, right) => left - right);
  const levels: Record<string, number> = {};
  let sum = 0;
  for (const level of solved) {
    const state = progress.levels[level.id];
    const previous = finishes.filter((at) => at < state.solvedAt!).pop() ?? progress.startedAt;
    const spent = Math.max(1000, state.solvedAt! - Math.max(state.openedAt!, previous));
    const par = (plan.timeLimit * 1000 * level.difficulty) / total;
    const factor = Math.min(1, Math.max(scoring.timeFloor, par / spent));
    const value = scoring.levelBase * level.difficulty * factor * scoring.errorDecay ** (state.errors + state.penalties) * (1 + scoring.depthBonus * level.depth);
    levels[level.id] = Math.round(value);
    sum += value;
  }
  const passRate = solved.reduce((acc, level) => acc + level.difficulty, 0) / total;
  const cleared = solved.length === plan.levels.length;
  let points = sum * (1 - scoring.passWeight + scoring.passWeight * passRate);
  if (cleared) {
    const deadline = progress.startedAt + plan.timeLimit * 1000;
    points *= 1 + scoring.clearBonus + (scoring.timeBonus * Math.max(0, deadline - endAt)) / (plan.timeLimit * 1000);
  }
  return { points: Math.round(points), passRate, cleared, levels };
};
