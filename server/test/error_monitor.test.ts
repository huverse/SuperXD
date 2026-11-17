import { ErrorCounter, ErrorMonitor, errorSignature, RelayLogger } from 'src/common/error_monitor';
import { errorAlertFoldMinutes, errorMonitorMaxSignatures, errorStatsMinutes } from 'src/common/relay_limits';

const minute = 60_000;

describe('错误签名', () => {
  it('认得 [模块] action=… errorType=…，易变的字段不进签名', () => {
    expect(errorSignature('[ChallengeContent] action=bank_load game=hanoi tier=3 version=2 errorType=SyntaxError keep=1', 'ChallengeContent')).toBe('ChallengeContent/bank_load/SyntaxError');
    expect(errorSignature('[Retention] action=run errorType=QueryFailedError', 'Retention')).toBe('Retention/run/QueryFailedError');
  });

  it('认不出的按上下文，过长与奇怪的字符截掉', () => {
    expect(errorSignature('没有格式的报错', 'ExceptionsHandler')).toBe('ExceptionsHandler/-/-');
    expect(errorSignature(new Error('x'), undefined)).toBe('unknown/-/-');
    expect(errorSignature('x', 'a b/c'.repeat(20)).length).toBeLessThanOrEqual(46);
  });
});

describe('错误计数与告警', () => {
  it('到了阈值才告警；同一签名折叠窗口内只写第一条，窗口结束写一条汇总', () => {
    const counter = new ErrorCounter();
    let now = 0;
    counter.record('Shed/RATE_LIMITED/503', 3);
    counter.record('Shed/RATE_LIMITED/503', 3);
    expect(counter.tick((now += minute))).toEqual([]);
    expect(counter.alerting).toBe(0);
    counter.record('Retention/run/QueryFailedError', 1);
    const first = counter.tick((now += minute));
    expect(first).toEqual(['[Alert] action=error_rate signature=Retention/run/QueryFailedError count=1 threshold=1 perMinute=1']);
    expect(counter.alerting).toBe(1);
    // 窗口里接着出错：不再原样写，累计。
    for (let index = 0; index < 5; index++) {
      counter.record('Retention/run/QueryFailedError', 1);
      counter.record('Retention/run/QueryFailedError', 1);
      expect(counter.tick((now += minute)).filter((line) => line.startsWith('[Alert]'))).toEqual([]);
    }
    // 窗口结束：一条汇总；之后再出错重新告警。
    now += errorAlertFoldMinutes * minute;
    expect(counter.tick(now).filter((line) => line.startsWith('[Alert]'))).toEqual([`[Alert] action=error_rate_folded signature=Retention/run/QueryFailedError minutes=5 count=10 foldMinutes=${errorAlertFoldMinutes}`]);
    expect(counter.alerting).toBe(0);
    counter.record('Retention/run/QueryFailedError', 1);
    expect(counter.tick((now += minute))[0]).toMatch(/^\[Alert\] action=error_rate signature=Retention/);
  });

  it('只告警过一次的窗口结束时不写汇总', () => {
    const counter = new ErrorCounter();
    counter.record('Redis/connection/Error', 1);
    expect(counter.tick(minute)).toHaveLength(1);
    expect(counter.tick(minute + errorAlertFoldMinutes * minute).filter((line) => line.startsWith('[Alert]'))).toEqual([]);
    expect(counter.alerting).toBe(0);
  });

  it('签名个数有上限，多的并进 other', () => {
    const counter = new ErrorCounter();
    for (let index = 0; index < errorMonitorMaxSignatures + 30; index++) counter.record(`Module${index}/run/Error`, 1);
    const lines = counter.tick(minute);
    expect(lines).toHaveLength(errorMonitorMaxSignatures + 1);
    expect(lines.at(-1)).toBe('[Alert] action=error_rate signature=other count=30 threshold=1 perMinute=1');
    expect(counter.alerting).toBe(errorMonitorMaxSignatures + 1);
  });

  it('每 errorStatsMinutes 分钟写一行汇总，没有错误时不写', () => {
    const counter = new ErrorCounter();
    let now = 0;
    const summaries: string[] = [];
    for (let tick = 1; tick <= errorStatsMinutes * 2; tick++) {
      if (tick === 3) {
        counter.record('A/run/Error', 1);
        counter.record('A/run/Error', 1);
        counter.record('Shed/RATE_LIMITED/503', 20);
      }
      summaries.push(...counter.tick((now += minute)).filter((line) => line.startsWith('[ErrorStats]')));
    }
    expect(summaries).toEqual([`[ErrorStats] action=summary minutes=${errorStatsMinutes} total=3 signatures=2 top=A/run/Error:2,Shed/RATE_LIMITED/503:1`]);
  });
});

describe('日志出口', () => {
  it('error 级日志先计数再照常输出，告警自己的日志不计', () => {
    const monitor = new ErrorMonitor();
    const logger = new RelayLogger(monitor);
    const printed: unknown[] = [];
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk) => {
      printed.push(chunk);
      return true;
    });
    try {
      logger.error('[Retention] action=run errorType=QueryFailedError', 'Retention');
      logger.error('[Alert] action=error_rate signature=x', 'ErrorMonitor');
      logger.warn('[Diagnostic] action=upload errorType=StoreFull', 'Diagnostic');
    } finally {
      vi.restoreAllMocks();
    }
    expect(printed.length).toBeGreaterThanOrEqual(2);
    expect(monitor.alerting).toBe(0);
    vi.spyOn(Date, 'now').mockReturnValue(minute);
    const errors: string[] = [];
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk) => {
      errors.push(String(chunk));
      return true;
    });
    try {
      monitor.tick();
    } finally {
      vi.restoreAllMocks();
    }
    expect(monitor.alerting).toBe(1);
    expect(errors.join('')).toContain('[Alert] action=error_rate signature=Retention/run/QueryFailedError count=1');
  });
});
