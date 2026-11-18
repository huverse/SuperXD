import { HttpStatus, Injectable, Logger } from '@nestjs/common';

import { rateSubjectOf } from 'src/common/client_ip';
import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { cleanupBatch, feedbackPerSourcePerHour, healthKeepDays, healthPauseKeepDays, healthReportMaxAgeDays, healthReportPerSourcePerHour, healthWindowDays } from 'src/common/relay_limits';
import { env } from 'src/config/env';
import { AppHealthRepository } from 'src/modules/app_health/app_health.repository';
import { appUpdateRolloutId, healthVerdict } from 'src/modules/app_health/app_health_rules';
import { periodOf } from 'src/modules/challenge/challenge_calendar';
import * as dtos from 'src/modules/app_health/app_health.dto';

// 业务时区的今天往前数 days 天（YYYY-MM-DD）。
const dayBefore = (now: Date, days: number) => {
  const today = periodOf(now.getTime(), 'day', env().businessTimeZone).date;
  return new Date(Date.parse(`${today}T00:00:00Z`) - days * 86400_000).toISOString().slice(0, 10);
};

// 分批更新的健康回报、自动暂停与意见反馈（规则与人工决策见 app_health_rules.ts）：都匿名、按来源限流；暂停的版本给 /v1/app/flags 带上（不签名，客户端只拿来少提示）。
@Injectable()
export class AppHealthService {
  private readonly logger = new Logger('AppHealth');

  constructor(
    private readonly health: AppHealthRepository,
    private readonly limiter: RateLimiter,
  ) {}

  // 只收已经过完、且在最近 healthReportMaxAgeDays 天里的那一天；不合的照样回 204（客户端记成发过，不重发）。
  async report(ip: string, body: dtos.HealthReportDto, now = new Date()) {
    const retryAfter = await this.limiter.hit('health_report', rateSubjectOf(ip), healthReportPerSourcePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '回报过于频繁', { retryAfter });
    if (body.day >= dayBefore(now, 0) || body.day < dayBefore(now, healthReportMaxAgeDays) || Number.isNaN(Date.parse(`${body.day}T00:00:00Z`))) return;
    await this.health.addReport(body.channel, body.platform, body.versionCode, body.day, body.fatal, { launch: body.launch, frames: body.frames }, now);
  }

  async feedback(ip: string, body: dtos.FeedbackDto, now = new Date()) {
    const retryAfter = await this.limiter.hit('app_feedback', rateSubjectOf(ip), feedbackPerSourcePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '提交过于频繁', { retryAfter });
    await this.health.addFeedback(body.channel, body.platform, body.versionCode, body.good, body.text.trim(), now);
  }

  // 停着的版本的开关名（app_update.<渠道>.<版本号>），/v1/app/flags 带上。
  async paused(): Promise<string[]> {
    return (await this.health.pausedVersions()).map((item) => appUpdateRolloutId(item.channel, item.versionCode));
  }

  // 每小时：各渠道比最近几天新旧两版的致命率，明显更差就停新版（已有记录的不动，解除过的不再停）。
  async watch(now = new Date()) {
    const since = dayBefore(now, healthWindowDays);
    for (const channel of await this.health.channelsSince(since)) {
      const samples = await this.health.samplesSince(channel, since);
      const versionCode = healthVerdict(samples);
      if (versionCode === null) continue;
      const [latest, previous] = samples;
      const reason = `致命率 ${latest.fatal}/${latest.reports}，上一版 ${previous.fatal}/${previous.reports}（${since} 起）`;
      if (await this.health.pause(channel, versionCode, reason, now)) this.logger.warn(`[AppHealth] action=pause channel=${channel} versionCode=${versionCode} reason=${reason}`);
    }
  }

  async sweep(now = new Date()) {
    let removed = 0;
    for (let round = 0; round < 20; round++) {
      const count = await this.health.deleteOld(dayBefore(now, healthKeepDays), new Date(now.getTime() - healthKeepDays * 86400_000), new Date(now.getTime() - healthPauseKeepDays * 86400_000), cleanupBatch);
      removed += count;
      if (count < cleanupBatch) break;
    }
    this.logger.log(`[AppHealth] action=sweep removed=${removed}`);
  }
}
