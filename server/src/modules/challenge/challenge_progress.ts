import { ChallengePlan, PlanLevel } from 'src/modules/challenge/challenge_plan';
import { withinStepLimit } from 'src/modules/challenge/judges/judges';

// 一局的进度与计分（纯函数，服务层在行锁里调用；人工决策见客户端 lib/playground/challenge/challenge_rules.dart 的 11-14 23:11 那条）。
// 时刻一律是服务器的 UTC 毫秒，客户端的时间不参与。

// locked：给它碎片的关还没全过；gated：碎片齐了、门还没开；open：能做；solved、failed（错交到上限）。
export type LevelState = 'locked' | 'gated' | 'open' | 'solved' | 'failed';
export type LevelProgress = { state: LevelState; openedAt: number | null; solvedAt: number | null; errors: number; penalties: number; submissions: number; fragment: number | null };
// penaltySeconds：门与终章输错扣的秒数合计（到点时刻已往前挪了这么多）；cleared：终章的最终密码输对了。
export type RunProgress = { startedAt: number; levels: Record<string, LevelProgress>; penaltySeconds: number; cleared: boolean };

const fresh = (state: LevelState, now: number): LevelProgress => ({ state, openedAt: state === 'open' ? now : null, solvedAt: null, errors: 0, penalties: 0, submissions: 0, fragment: null });

// 开局：不收碎片的关直接开，其余锁着。
export const startProgress = (plan: ChallengePlan, now: number): RunProgress => ({
  startedAt: now,
  levels: Object.fromEntries(plan.levels.map((level) => [level.id, fresh(level.inputs.length === 0 ? 'open' : 'locked', now)])),
  penaltySeconds: 0,
  cleared: false,
});

// 追加的加试题直接开着。
export const addExtra = (plan: ChallengePlan, progress: RunProgress, level: PlanLevel, now: number) => {
  plan.levels.push(level);
  progress.levels[level.id] = fresh('open', now);
};

export type JudgedAnswer = { solved: boolean; penalties: number; steps: number | null };

// 记一次判定。这一关开着：解开就记过关时刻与碎片（要最少步数的超过上限不算解开：多数游戏多一步都不行，汉诺塔第 2 版放宽到 1.2 倍，见 judges.ts 的 withinStepLimit），收它碎片的那关碎片都齐了就到门前；没解开计一次错交，到上限算没过。
// 这一关已经过了（重做一遍看碎片）：对了再给一次碎片，不改进度，错了也不计错交。返回这次算不算解开与给的碎片。
export const recordVerdict = (plan: ChallengePlan, progress: RunProgress, levelId: string, judged: JudgedAnswer, now: number) => {
  const level = plan.levels.find((item) => item.id === levelId)!;
  const state = progress.levels[levelId];
  state.submissions++;
  const solved = judged.solved && (level.minimum === null || judged.steps === null || withinStepLimit(level.game, level.version ?? 1, level.minimum, judged.steps));
  if (state.state === 'solved') return { solved, fragment: solved ? state.fragment : null, replay: true };
  if (!solved) {
    state.errors++;
    if (state.errors >= plan.scoring.maxErrors) state.state = 'failed';
    return { solved, fragment: null, replay: false };
  }
  state.state = 'solved';
  state.solvedAt = now;
  state.penalties = judged.penalties;
  state.fragment = level.extraOf === null ? level.fragment : null;
  if (level.output !== null) {
    const target = plan.levels.find((item) => item.id === level.output)!;
    if (target.inputs.every((input) => progress.levels[input].state === 'solved')) progress.levels[target.id].state = 'gated';
  }
  return { solved, fragment: state.fragment, replay: false };
};

// 门上的数：给它碎片的几关的碎片相加或相乘（开局时就算好，见 challenge_plan.ts）。
export const gateValue = (level: PlanLevel) => level.gate!.value;

// 终章的最终密码：全部关（不含加试题）的碎片相加。
export const finalValue = (plan: ChallengePlan, progress: RunProgress) =>
  plan.levels.filter((level) => level.extraOf === null).reduce((sum, level) => sum + (progress.levels[level.id].fragment ?? 0), 0);

// 终章能不能开：全部关都过了、加试题也都做完了，还没输对过。
export const finalReady = (plan: ChallengePlan, progress: RunProgress) => !progress.cleared && plan.levels.every((level) => progress.levels[level.id].state === 'solved');

// 开门：这一关在门前、数对了就开；输错扣 gatePenalty 秒（由服务层把到点时刻往前挪）。返回对不对。
export const openGate = (plan: ChallengePlan, progress: RunProgress, levelId: string, value: number, now: number) => {
  const level = plan.levels.find((item) => item.id === levelId)!;
  const state = progress.levels[levelId];
  if (value !== gateValue(level)) {
    progress.penaltySeconds += plan.scoring.gatePenalty;
    return false;
  }
  state.state = 'open';
  state.openedAt = now;
  return true;
};

// 终章：最终密码对了就是全部过关；输错同门一样扣时间。
export const openFinal = (plan: ChallengePlan, progress: RunProgress, value: number) => {
  if (value !== finalValue(plan, progress)) {
    progress.penaltySeconds += plan.scoring.gatePenalty;
    return false;
  }
  progress.cleared = true;
  return true;
};

// 这一局还能不能接着做：终章输对了是 cleared；没有开着的关、没有能开的门、终章也开不了（剩下的都因为前面没过而开不了）是 stuck；否则 null。
export const runOutcome = (plan: ChallengePlan, progress: RunProgress) => {
  if (progress.cleared) return 'cleared';
  if (finalReady(plan, progress)) return null;
  return Object.values(progress.levels).some((level) => level.state === 'open' || level.state === 'gated') ? null : 'stuck';
};

export type RunScore = { points: number; passRate: number; cleared: boolean; levels: Record<string, number> };

// 一关的分段用时：从它开门（或开局）、或这一局上一次过关（两者取晚的）起，到它过关（一人一次做一关，同竞速比赛的分段计时）。
export const spentOn = (progress: RunProgress, levelId: string) => {
  const state = progress.levels[levelId];
  const previous = Object.values(progress.levels).map((level) => level.solvedAt).filter((at): at is number => at !== null && at < state.solvedAt!).sort((left, right) => left - right).pop() ?? progress.startedAt;
  return Math.max(1000, state.solvedAt! - Math.max(state.openedAt!, previous));
};

// 计分（参数是开局时的配置快照，见 challenge_config.ts 的 ChallengeScoring；加试题不计分）：
// - 每关基础分 levelBase × 难度分 d（按回调后的预计用时取对数）；参考用时 = 回调后的预计用时 × parSlack；
// - 时间系数 = 参考用时 ÷ 分段用时，夹在 timeFloor 到 1 之间；每错交一次（含答案里自带的失误）乘一次 errorDecay；串联第 k 层再乘 1 + depthBonus × k。
// - 合计 ×（1 − passWeight + passWeight × 按难度加权的过关率）；终章输对（全部过关）再 ×（1 + clearBonus + timeBonus × 剩余时间 ÷ 限时）。取整。
// deadline 是这一局的到点时刻（已扣掉门与终章输错的时间）。
export const scoreRun = (plan: ChallengePlan, progress: RunProgress, endAt: number, deadline: number): RunScore => {
  const { scoring } = plan;
  const counted = plan.levels.filter((level) => level.extraOf === null);
  const total = counted.reduce((sum, level) => sum + level.difficulty, 0);
  const solved = counted.filter((level) => progress.levels[level.id].state === 'solved');
  const levels: Record<string, number> = {};
  let sum = 0;
  for (const level of solved) {
    const state = progress.levels[level.id];
    const factor = Math.min(1, Math.max(scoring.timeFloor, (level.expected * 1000 * scoring.parSlack) / spentOn(progress, level.id)));
    const value = scoring.levelBase * level.difficulty * factor * scoring.errorDecay ** (state.errors + state.penalties) * (1 + scoring.depthBonus * level.depth);
    levels[level.id] = Math.round(value);
    sum += value;
  }
  const passRate = solved.reduce((acc, level) => acc + level.difficulty, 0) / total;
  let points = sum * (1 - scoring.passWeight + scoring.passWeight * passRate);
  if (progress.cleared) points *= 1 + scoring.clearBonus + (scoring.timeBonus * Math.max(0, deadline - endAt)) / (plan.timeLimit * 1000);
  return { points: Math.round(points), passRate, cleared: progress.cleared, levels };
};
