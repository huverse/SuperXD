import { HttpStatus, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { randomBytes } from 'node:crypto';
import { EntityManager } from 'typeorm';

import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { challengeRequestsPerDevicePerHour, challengeStartsPerAccountPerHour, challengeSweepBatch } from 'src/common/relay_limits';
import { AccountRepository } from 'src/modules/account/account.repository';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';
import { ChallengeRepository, RunRow } from 'src/modules/challenge/challenge.repository';
import { consumerGames } from 'src/modules/challenge/challenge_config';
import { ChallengeContent } from 'src/modules/challenge/challenge_content';
import { ChallengePace } from 'src/modules/challenge/challenge_pace';
import { ChallengePlan, ChallengePlanError, extraLevel, planChallenge } from 'src/modules/challenge/challenge_plan';
import { addExtra, finalReady, openFinal, openGate, recordVerdict, runOutcome, RunProgress, scoreRun, spentOn, startProgress } from 'src/modules/challenge/challenge_progress';
import { clientGames, judge, judgedGames } from 'src/modules/challenge/judges/judges';
import { PointsService } from 'src/modules/points/points.service';
import * as dtos from 'src/modules/challenge/challenge.dto';

// 挑战（人工决策见客户端 lib/playground/challenge/challenge_rules.dart）：服务器出题、逐关核对、计时（不暂停）与结算，全程联网。
// 11-14 起关与关之间是碎片与门：过关给一次碎片，收碎片的关先开门（输错扣时间），全部过了输终章的最终密码才算全部过关；解得快得不正常追加加试题。
// 一个账号同时只有一局；交答案、结算都在这一局的行锁里做；到点没交的局由 ChallengeTasks 定时结算，用户不回来也照样记分。
// 结算只补超过这个挑战以前最好成绩的差额（11-12 用户选定），积分与最好成绩、这一局的结算在同一事务里写。
// 有门票的挑战开局即扣（11-14 用户选「开局扣票不退」，见 points.service.ts）：扣积分与插入这一局同一事务，积分不够或没开成都不扣。
@Injectable()
export class ChallengeService implements OnModuleInit {
  private readonly logger = new Logger('Challenge');

  constructor(
    private readonly runs: ChallengeRepository,
    private readonly content: ChallengeContent,
    private readonly accounts: AccountRepository,
    private readonly hooks: AccountDataHooks,
    private readonly points: PointsService,
    private readonly limiter: RateLimiter,
    private readonly pace: ChallengePace,
  ) {}

  onModuleInit() {
    this.hooks.register((manager, accountIds) => this.deleteAccountsIn(manager, accountIds));
  }

  // 删这些账号的挑战局与最好成绩（调用方事务内）：注销账号与「删除游乐场与积分」共用。
  deleteAccountsIn(manager: EntityManager, accountIds: string[]) {
    return this.runs.deleteAccounts(manager, accountIds);
  }

  async list(deviceId: string, games: string[]): Promise<dtos.ChallengeListDto> {
    const accountId = await this.accountOf(deviceId);
    const now = Date.now();
    const supported = clientGames(games);
    const open = await this.content.openChallenges(now);
    const best = await this.runs.bestOf(accountId, open.map((challenge) => challenge.id));
    return {
      serverTime: now,
      activeRun: await this.runs.activeRunOf(accountId),
      challenges: open.map((challenge) => ({
        id: challenge.id,
        title: challenge.title,
        label: challenge.template.label,
        levels: challenge.template.nodes.length,
        tiers: challenge.template.nodes.map((node) => node.tier),
        edges: challenge.template.edges.map(([from, to]) => [challenge.template.nodes.findIndex((node) => node.id === from), challenge.template.nodes.findIndex((node) => node.id === to)]),
        timeLimit: challenge.template.timeLimit,
        endsAt: challenge.end,
        best: best.get(challenge.id) ?? null,
        // 每一关的候选游戏里至少有一个这个客户端玩得了（游戏与题面写法版本这份判定都认得）。
        playable: challenge.template.nodes.every((node) => (node.games ?? [...(challenge.template.edges.some(([, to]) => to === node.id) ? consumerGames : judgedGames)]).some((game) => supported.has(game))),
        ticket: challenge.ticket,
      })),
    };
  }

  async start(deviceId: string, challengeId: string, games: string[]): Promise<dtos.ChallengeRunDto> {
    const accountId = await this.accountOf(deviceId);
    const retryAfter = await this.limiter.hit('challenge_start', accountId, challengeStartsPerAccountPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '开局过于频繁', { retryAfter });
    // 进行中的那一局到点了还没被定时任务结算，就先结算掉，不挡新的一局。
    const active = await this.runs.activeRunOf(accountId);
    if (active !== null && (await this.runs.withRun(active, accountId, async (manager, run) => run !== null && (await this.settleIfDue(manager, run, Date.now())).active))) {
      throw new RelayError(RelayCode.runActive, HttpStatus.CONFLICT, '已有进行中的一局', { runId: active });
    }
    const now = Date.now();
    const challenge = await this.content.openChallenge(challengeId, now);
    const config = await this.content.currentConfig();
    if (challenge === null || config === null) throw new RelayError(RelayCode.challengeNotFound, HttpStatus.NOT_FOUND, '挑战不存在或不在开放时间');
    let plan: ChallengePlan;
    try {
      plan = await planChallenge(
        { challengeId, title: challenge.title, template: challenge.template, endsAt: challenge.end, scoring: config.scoring, supported: clientGames(games), allGames: judgedGames, pace: await this.pace.factors(now) },
        (game, tier, version) => this.content.bank(game, tier, version),
      );
    } catch (error) {
      if (!(error instanceof ChallengePlanError)) throw error;
      this.logger.warn(`[Challenge] action=plan challengeId=${challengeId} reason=${error.message}`);
      throw new RelayError(RelayCode.challengeUnavailable, HttpStatus.CONFLICT, '这个挑战暂时开不了');
    }
    const run: RunRow = {
      runId: randomBytes(16).toString('base64url'),
      accountId,
      challengeId,
      active: true,
      deadline: new Date(now + plan.timeLimit * 1000),
      plan: JSON.stringify(plan),
      progress: JSON.stringify(startProgress(plan, now)),
      ending: null,
      points: null,
      awarded: null,
      endTime: null,
    };
    const charge = async (manager: EntityManager) => {
      if (challenge.ticket > 0) await this.points.spendIn(manager, accountId, challenge.ticket, run.runId, `${plan.label} · ${plan.title} 门票`, new Date(now));
    };
    if (!(await this.runs.insertRun(run, new Date(now), charge))) {
      throw new RelayError(RelayCode.runActive, HttpStatus.CONFLICT, '已有进行中的一局', { runId: (await this.runs.activeRunOf(accountId)) ?? '' });
    }
    this.logger.log(`[Challenge] action=start challengeId=${challengeId} runId=${run.runId} ticket=${challenge.ticket} levels=${plan.levels.map((level) => level.game).join(',')}`);
    return this.viewOf(run, now);
  }

  async view(deviceId: string, runId: string): Promise<dtos.ChallengeRunDto> {
    const accountId = await this.accountOf(deviceId);
    return this.locked(runId, accountId, async (manager, run) => {
      const now = Date.now();
      return this.viewOf(await this.settleIfDue(manager, run, now), now);
    });
  }

  async answer(deviceId: string, runId: string, levelId: string, attempt: number, answer: unknown): Promise<dtos.ChallengeAnswerDto> {
    const accountId = await this.accountOf(deviceId);
    return this.locked(runId, accountId, async (manager, found) => {
      const now = Date.now();
      const run = await this.settleIfDue(manager, found, now);
      const plan = JSON.parse(run.plan) as ChallengePlan;
      const progress = JSON.parse(run.progress) as RunProgress;
      const level = plan.levels.find((item) => item.id === levelId);
      const state = progress.levels[levelId];
      if (level === undefined || state === undefined) return new RelayError(RelayCode.levelLocked, HttpStatus.CONFLICT, '没有这一关', { run: this.viewOf(run, now) });
      // 同一个号重发（上一次的回复丢了）：回那一次的结果，不再计数。
      if (attempt < state.submissions) {
        const correct = state.state === 'solved' && attempt === state.submissions - 1;
        return { correct, fragment: correct ? state.fragment : null, extra: correct ? (plan.levels.find((item) => item.extraOf === levelId)?.id ?? null) : null, run: this.viewOf(run, now) };
      }
      if (!run.active) return new RelayError(RelayCode.runOver, HttpStatus.CONFLICT, '这一局已经结束', { run: this.viewOf(run, now) });
      if ((state.state !== 'open' && state.state !== 'solved') || attempt !== state.submissions) return new RelayError(RelayCode.levelLocked, HttpStatus.CONFLICT, '这一关现在不能交', { run: this.viewOf(run, now) });
      const verdict = judge(level.game, level.puzzle, answer, level.version ?? 1);
      const judged = verdict.kind === 'solved' ? { solved: true, penalties: verdict.penalties, steps: verdict.steps } : { solved: false, penalties: 0, steps: null };
      const result = recordVerdict(plan, progress, levelId, judged, now);
      let extra: string | null = null;
      if (result.solved && !result.replay) {
        const spent = spentOn(progress, levelId);
        this.pace.record(level.game, spent, level.baseExpected, now);
        // 快得不正常（不到预计用时的 extraRatio，也不到 extraFloor 秒）：追加一道同一游戏的加试题，做完才开终章。
        const extras = plan.levels.filter((item) => item.extraOf !== null).length;
        if (level.extraOf === null && extras < plan.scoring.maxExtras && spent < Math.min(level.expected * 1000 * plan.scoring.extraRatio, plan.scoring.extraFloor * 1000)) {
          const added = await extraLevel(plan, level, (game, tier, version) => this.content.bank(game, tier, version), await this.pace.factors(now));
          if (added !== null) {
            addExtra(plan, progress, added, now);
            extra = added.id;
          }
        }
      }
      this.logger.log(`[Challenge] action=answer runId=${runId} level=${levelId} game=${level.game} verdict=${verdict.kind} solved=${result.solved} replay=${result.replay} extra=${extra ?? ''}`);
      const outcome = runOutcome(plan, progress);
      const updated = { ...run, progress: JSON.stringify(progress), plan: extra === null ? run.plan : JSON.stringify(plan) };
      const saved = outcome === null ? await this.save(manager, updated, now, extra !== null) : await this.settle(manager, updated, outcome, now);
      return { correct: result.solved, fragment: result.fragment, extra, run: this.viewOf(saved, now) };
    });
  }

  // 开门：碎片齐了、门上的数对了就开这一关；输错扣 gatePenalty 秒（到点时刻往前挪，不说哪个碎片错了）。
  async gate(deviceId: string, runId: string, levelId: string, value: number): Promise<dtos.ChallengeGateResultDto> {
    return this.enter(deviceId, runId, (plan, progress, now) => {
      if (progress.levels[levelId]?.state !== 'gated') return null;
      return openGate(plan, progress, levelId, value, now);
    }, levelId);
  }

  // 终章：全部关（含加试题）都过了才能输；最终密码 = 全部碎片相加，输对就是全部过关、马上结算。
  async final(deviceId: string, runId: string, value: number): Promise<dtos.ChallengeGateResultDto> {
    return this.enter(deviceId, runId, (plan, progress) => (finalReady(plan, progress) ? openFinal(plan, progress, value) : null), 'final');
  }

  // 门与终章共用：锁住这一局，try 返回 null 是现在不能输（回 levelLocked 与现状），否则按对错存进度；输错把到点时刻往前挪。
  private async enter(deviceId: string, runId: string, attempt: (plan: ChallengePlan, progress: RunProgress, now: number) => boolean | null, what: string): Promise<dtos.ChallengeGateResultDto> {
    const accountId = await this.accountOf(deviceId);
    return this.locked(runId, accountId, async (manager, found) => {
      const now = Date.now();
      const run = await this.settleIfDue(manager, found, now);
      if (!run.active) return new RelayError(RelayCode.runOver, HttpStatus.CONFLICT, '这一局已经结束', { run: this.viewOf(run, now) });
      const plan = JSON.parse(run.plan) as ChallengePlan;
      const progress = JSON.parse(run.progress) as RunProgress;
      const correct = attempt(plan, progress, now);
      if (correct === null) return new RelayError(RelayCode.levelLocked, HttpStatus.CONFLICT, '现在不能输', { run: this.viewOf(run, now) });
      const deadline = correct ? run.deadline : new Date(run.deadline.getTime() - plan.scoring.gatePenalty * 1000);
      this.logger.log(`[Challenge] action=gate runId=${runId} gate=${what} correct=${correct}`);
      const updated = { ...run, progress: JSON.stringify(progress), deadline };
      if (!correct) await this.runs.updateRun(manager, run.runId, { progress: updated.progress, deadline }, new Date(now));
      const outcome = runOutcome(plan, progress);
      const saved = outcome !== null ? await this.settle(manager, updated, outcome, now) : correct ? await this.save(manager, updated, now, false) : await this.settleIfDue(manager, updated, now);
      return { correct, run: this.viewOf(saved, now) };
    });
  }

  // 玩家提前结束：按已过的关结算。
  async end(deviceId: string, runId: string): Promise<dtos.ChallengeRunDto> {
    const accountId = await this.accountOf(deviceId);
    return this.locked(runId, accountId, async (manager, found) => {
      const now = Date.now();
      const run = await this.settleIfDue(manager, found, now);
      return this.viewOf(run.active ? await this.settle(manager, run, 'ended', now) : run, now);
    });
  }

  // 定时任务：结算到点没交的局，每批最多 challengeSweepBatch 局，返回结算的局数。
  async settleDue(now: number) {
    const due = await this.runs.dueRuns(new Date(now), challengeSweepBatch);
    for (const runId of due) {
      await this.runs.withRun(runId, null, async (manager, run) => {
        if (run !== null) await this.settleIfDue(manager, run, now);
      });
    }
    return due.length;
  }

  // 锁住这一局做 work：work 返回 RelayError 表示要回错误，但事务照常提交（顺带做的到点结算不能因为回错误而回滚）。
  private async locked<T>(runId: string, accountId: string, work: (manager: EntityManager, run: RunRow) => Promise<T | RelayError>): Promise<T> {
    const result = await this.runs.withRun(runId, accountId, async (manager, run) => (run === null ? new RelayError(RelayCode.runNotFound, HttpStatus.NOT_FOUND, '这一局不存在') : work(manager, run)));
    if (result instanceof RelayError) throw result;
    return result;
  }

  private async settleIfDue(manager: EntityManager, run: RunRow, now: number) {
    return run.active && run.deadline.getTime() <= now ? this.settle(manager, run, 'timeout', now) : run;
  }

  private async save(manager: EntityManager, run: RunRow, now: number, withPlan: boolean) {
    await this.runs.updateRun(manager, run.runId, { progress: run.progress, plan: withPlan ? run.plan : undefined }, new Date(now));
    return run;
  }

  // 结算：到点的按到点时刻算。成绩超过这个挑战以前的最好成绩才补差额进积分（幂等键是这一局的编号），最好成绩一并更新。
  private async settle(manager: EntityManager, run: RunRow, ending: string, now: number) {
    const plan = JSON.parse(run.plan) as ChallengePlan;
    const endAt = Math.min(now, run.deadline.getTime());
    const score = scoreRun(plan, JSON.parse(run.progress) as RunProgress, endAt, run.deadline.getTime());
    const best = await this.runs.lockBest(manager, run.accountId, run.challengeId);
    const awarded = Math.max(0, score.points - best);
    if (awarded > 0) {
      await this.points.grantIn(manager, run.accountId, awarded, 'challenge', run.runId, `${plan.label} · ${plan.title}`, new Date(now));
      await this.runs.saveBest(manager, { accountId: run.accountId, challengeId: run.challengeId, points: score.points, runId: run.runId, endsAt: new Date(plan.endsAt) }, new Date(now));
    }
    const settled: RunRow = { ...run, active: false, ending, points: score.points, awarded, endTime: new Date(endAt) };
    await this.runs.updateRun(manager, run.runId, { progress: run.progress, plan: run.plan, ending, points: score.points, awarded, endTime: settled.endTime, settle: true }, new Date(now));
    this.logger.log(`[Challenge] action=settle runId=${run.runId} ending=${ending} points=${score.points} awarded=${awarded} passRate=${score.passRate.toFixed(2)}`);
    return settled;
  }

  private viewOf(run: RunRow, now: number): dtos.ChallengeRunDto {
    const plan = JSON.parse(run.plan) as ChallengePlan;
    const progress = JSON.parse(run.progress) as RunProgress;
    return {
      runId: run.runId,
      challengeId: run.challengeId,
      title: plan.title,
      label: plan.label,
      timeLimit: plan.timeLimit,
      startedAt: progress.startedAt,
      deadline: run.deadline.getTime(),
      serverTime: now,
      state: run.active ? 'running' : 'settled',
      penaltySeconds: progress.penaltySeconds,
      final: progress.cleared ? 'cleared' : finalReady(plan, progress) ? 'ready' : 'locked',
      levels: plan.levels.map((level) => {
        const state = progress.levels[level.id];
        const opened = state.state === 'open' || state.state === 'solved' || state.state === 'failed';
        return {
          id: level.id,
          game: level.game,
          tier: level.tier,
          difficulty: level.difficulty,
          expected: level.expected,
          inputs: level.inputs,
          output: level.output,
          letter: level.letter,
          state: state.state,
          submissions: state.submissions,
          errors: state.errors + state.penalties,
          minimum: level.minimum,
          gate: level.gate === null ? null : { op: level.gate.op, value: opened ? level.gate.value : null },
          consume: level.consume,
          extraOf: level.extraOf,
          // 碎片只在过关那次回复里给，局面里不给；题面开着或过了（重做看碎片）才给。
          puzzle: run.active && (state.state === 'open' || state.state === 'solved') ? level.puzzle : null,
        };
      }),
      result: run.active ? null : { points: run.points ?? 0, awarded: run.awarded ?? 0, ending: run.ending ?? 'ended' },
    };
  }

  private async accountOf(deviceId: string) {
    const retryAfter = await this.limiter.hit('challenge_request', deviceId, challengeRequestsPerDevicePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '请求过于频繁', { retryAfter });
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    return accountId;
  }
}
