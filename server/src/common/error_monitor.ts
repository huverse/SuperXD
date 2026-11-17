import { ConsoleLogger, Global, Injectable, Logger, Module } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';

import { errorAlertFoldMinutes, errorAlertPerMinute, errorMonitorMaxSignatures, errorStatsMinutes } from 'src/common/relay_limits';

// [人工决策-2026-11-17 21:24:25] 错误计数与告警（用户同意审查建议 P1-4，按最佳实践做、不引入付费服务）：以前错误只进 docker 日志，没人看就等于没有。
// 现在按签名「模块/动作/错误类型」（取自日志的 [模块] action=… errorType=…，易变的字段不进签名，所以桶数有界）每分钟计数，
// 一分钟里到了这个签名的阈值就写一行 [Alert]；同一签名 errorAlertFoldMinutes 分钟内只原样写第一条，其余累计成窗口结束时的一条汇总（全局规则「告警必须自带聚合上限」）。
// 阈值：error 级日志在这个服务里只写给意外的失败（预期的拒绝是不记日志的 RelayError，降级是 warn），所以一分钟一次就告警；
// 主动卸载负载的 503（哈希排队、下载并发、诊断包目录满）偶有是正常的，一分钟到 shedAlertPerMinute 次才告警。
// 通知不另接服务：/v1/health/ready 带「最近一个窗口里告警过的签名个数」，GitHub 上每 30 分钟的探活（relay-health.yml）读到非零就失败、发邮件，明细在服务器日志里。
// 每 errorStatsMinutes 分钟另写一行汇总（有错误时才写）。最多跟踪 errorMonitorMaxSignatures 个签名，多的并进 other。
export class ErrorCounter {
  private minute = new Map<string, { count: number; threshold: number }>();
  private stats = new Map<string, number>();
  private folds = new Map<string, { until: number; minutes: number; errors: number }>();
  private ticks = 0;

  record(signature: string, threshold: number) {
    const key = this.minute.has(signature) || this.minute.size < errorMonitorMaxSignatures ? signature : 'other';
    const entry = this.minute.get(key) ?? { count: 0, threshold };
    entry.count++;
    this.minute.set(key, entry);
  }

  // 每分钟调一次，返回要写的告警与汇总行。
  tick(now: number): string[] {
    const lines: string[] = [];
    for (const [signature, fold] of this.folds) {
      if (now < fold.until) continue;
      if (fold.minutes > 0) lines.push(`[Alert] action=error_rate_folded signature=${signature} minutes=${fold.minutes} count=${fold.errors} foldMinutes=${errorAlertFoldMinutes}`);
      this.folds.delete(signature);
    }
    for (const [signature, { count, threshold }] of this.minute) {
      this.stats.set(signature, (this.stats.get(signature) ?? 0) + count);
      if (count < threshold) continue;
      const fold = this.folds.get(signature);
      if (fold === undefined) {
        lines.push(`[Alert] action=error_rate signature=${signature} count=${count} threshold=${threshold} perMinute=1`);
        this.folds.set(signature, { until: now + errorAlertFoldMinutes * 60_000, minutes: 0, errors: 0 });
      } else {
        fold.minutes++;
        fold.errors += count;
      }
    }
    this.minute = new Map();
    if (++this.ticks % errorStatsMinutes === 0 && this.stats.size > 0) {
      const sorted = [...this.stats].sort((left, right) => right[1] - left[1]);
      const total = sorted.reduce((sum, [, count]) => sum + count, 0);
      lines.push(`[ErrorStats] action=summary minutes=${errorStatsMinutes} total=${total} signatures=${sorted.length} top=${sorted.slice(0, 10).map(([signature, count]) => `${signature}:${count}`).join(',')}`);
      this.stats = new Map();
    }
    return lines;
  }

  // 还在折叠窗口里的签名个数，即最近 errorAlertFoldMinutes 分钟里告警过几种错误。
  get alerting(): number {
    return this.folds.size;
  }
}

const signaturePattern = /^\[(\w{1,40})\][^\n]*?\baction=([\w.-]{1,40})[^\n]*?\berrorType=([\w.-]{1,60})/;

// 日志的签名：认得 [模块] action=… errorType=… 的按它，否则按日志的上下文（Nest 自己的错误）。
export const errorSignature = (message: unknown, context: string | undefined): string => {
  const match = typeof message === 'string' ? signaturePattern.exec(message) : null;
  return match ? `${match[1]}/${match[2]}/${match[3]}` : `${(context ?? 'unknown').replace(/\W/g, '').slice(0, 40)}/-/-`;
};

@Injectable()
export class ErrorMonitor {
  private readonly logger = new Logger(ErrorMonitor.name);
  private readonly counter = new ErrorCounter();

  recordLog(message: unknown, context: string | undefined) {
    if (context === ErrorMonitor.name) return;
    this.counter.record(errorSignature(message, context), errorAlertPerMinute);
  }

  // 主动卸载负载的 503：签名是 Shed/错误码/状态码。
  recordShed(code: string, status: number, threshold: number) {
    this.counter.record(`Shed/${code}/${status}`, threshold);
  }

  get alerting(): number {
    return this.counter.alerting;
  }

  @Interval(60_000)
  tick() {
    for (const line of this.counter.tick(Date.now())) this.logger.error(line);
  }
}

// 全部 error 级日志先计数再照常输出；由 createRelayApp 装上（app.useLogger）。
export class RelayLogger extends ConsoleLogger {
  constructor(private readonly monitor: ErrorMonitor) {
    super();
  }

  override error(message: unknown, ...optionalParams: unknown[]) {
    const context = optionalParams.length > 0 && typeof optionalParams[optionalParams.length - 1] === 'string' ? (optionalParams[optionalParams.length - 1] as string) : undefined;
    this.monitor.recordLog(message, context);
    super.error(message, ...optionalParams);
  }
}

@Global()
@Module({ providers: [ErrorMonitor], exports: [ErrorMonitor] })
export class ErrorMonitorModule {}
