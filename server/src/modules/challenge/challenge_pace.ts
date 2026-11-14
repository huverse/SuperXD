import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Column, Entity, Repository } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';
import { challengePaceCacheMs, challengePaceKeepWeeks, challengePaceMaxFactor, challengePaceMinSamples, challengePaceWeeks } from 'src/common/relay_limits';
import { env } from 'src/config/env';
import { periodOf } from 'src/modules/challenge/challenge_calendar';

// 预计用时按真实过关用时回调（[人工决策-2026-11-14 23:11:48] 用户选「预计用时做标尺」，见客户端 lib/playground/puzzle_rules.dart 文件头）：
// 每过一关记一次「分段用时 ÷ 题库预计用时」，按 2 的 1/4 次方分档（1/8 到 8 倍，共 25 档）计数；每个游戏取近 challengePaceWeeks 周用时比的中位数
// 作这个游戏的倍数，开局时乘在题库预计用时上（参考用时与难度分都用回调后的）。直方图是预聚合表（游戏 × 周 × 档，行数有界），不在局表上实时聚合；
// 中位数抗得住个别机器秒解或挂机的局；倍数夹在 1/2 到 2 倍。只是分析用的计数，写失败只记日志，不影响过关。

const bucketSpan = 4;
const bucketMax = 12;

@Entity('challenge_pace')
export class ChallengePaceEntity extends BaseEntity {
  @Column({ name: 'game', type: 'varchar', length: 24 }) game: string;
  // 业务时区的周一（YYYY-MM-DD）。
  @Column({ name: 'week', type: 'char', length: 10 }) week: string;
  @Column({ name: 'bucket', type: 'tinyint' }) bucket: number;
  @Column({ name: 'count', type: 'int', unsigned: true }) count: number;
}

// 存储端口：服务只依赖这个抽象。
export abstract class ChallengePaceRepository {
  abstract record(game: string, week: string, bucket: number, now: Date): Promise<void>;
  // since 那周（含）以来每个游戏每档的次数合计。
  abstract histogram(since: string): Promise<{ game: string; bucket: number; count: number }[]>;
  abstract deleteBefore(week: string, limit: number): Promise<number>;
}

@Injectable()
export class TypeormChallengePaceRepository extends ChallengePaceRepository {
  constructor(@InjectRepository(ChallengePaceEntity) private readonly rows: Repository<ChallengePaceEntity>) {
    super();
  }

  async record(game: string, week: string, bucket: number, now: Date) {
    await this.rows.query(
      'INSERT INTO challenge_pace (game, week, bucket, count, create_time, update_time) VALUES (?, ?, ?, 1, ?, ?) ON DUPLICATE KEY UPDATE count = count + 1, update_time = VALUES(update_time)',
      [game, week, bucket, now, now],
    );
  }

  async histogram(since: string) {
    const rows = (await this.rows.query('SELECT game, bucket, CAST(SUM(count) AS UNSIGNED) AS count FROM challenge_pace WHERE week >= ? GROUP BY game, bucket', [since])) as { game: string; bucket: number; count: string | number }[];
    return rows.map((row) => ({ game: row.game, bucket: Number(row.bucket), count: Number(row.count) }));
  }

  async deleteBefore(week: string, limit: number) {
    const result = (await this.rows.query('DELETE FROM challenge_pace WHERE week < ? LIMIT ?', [week, limit])) as { affectedRows: number };
    return result.affectedRows;
  }
}

// 用时比的档：log2(比) × 4 取整，夹在 −12 到 12。
export const paceBucket = (spentMs: number, expectedSeconds: number) => Math.max(-bucketMax, Math.min(bucketMax, Math.round(Math.log2(spentMs / (expectedSeconds * 1000)) * bucketSpan)));

// 一个游戏的倍数：次数够才算，取中位数所在的档（2 的 档/4 次方），夹在 1/2 到 2 倍；不够为 1。
export const paceFactor = (counts: Map<number, number>) => {
  const total = [...counts.values()].reduce((sum, count) => sum + count, 0);
  if (total < challengePaceMinSamples) return 1;
  let seen = 0;
  for (let bucket = -bucketMax; bucket <= bucketMax; bucket++) {
    seen += counts.get(bucket) ?? 0;
    if (seen * 2 >= total) return Math.min(challengePaceMaxFactor, Math.max(1 / challengePaceMaxFactor, 2 ** (bucket / bucketSpan)));
  }
  return 1;
};

const weekOf = (now: number) => periodOf(now, 'week', env().businessTimeZone).date;

@Injectable()
export class ChallengePace {
  private readonly logger = new Logger('ChallengePace');
  private cache: { at: number; factors: Map<string, number> } | null = null;

  constructor(private readonly rows: ChallengePaceRepository) {}

  // 记一次过关（热路径上的补充记录，不等它写完，失败只记日志）。
  record(game: string, spentMs: number, baseExpected: number, now: number) {
    this.rows.record(game, weekOf(now), paceBucket(spentMs, baseExpected), new Date(now)).catch((error: unknown) => {
      console.error(error);
      this.logger.error(`[ChallengePace] action=record game=${game} errorType=${error instanceof Error ? error.constructor.name : typeof error}`);
    });
  }

  // 各游戏此刻的倍数（每实例缓存一小时，过期了重读一次直方图）。
  async factors(now: number): Promise<(game: string) => number> {
    if (this.cache === null || now - this.cache.at >= challengePaceCacheMs) {
      const histograms = new Map<string, Map<number, number>>();
      for (const row of await this.rows.histogram(weekOf(now - (challengePaceWeeks - 1) * 7 * 86400_000))) {
        const counts = histograms.get(row.game) ?? new Map<number, number>();
        counts.set(row.bucket, row.count);
        histograms.set(row.game, counts);
      }
      this.cache = { at: now, factors: new Map([...histograms].map(([game, counts]) => [game, paceFactor(counts)])) };
    }
    const factors = this.cache.factors;
    return (game) => factors.get(game) ?? 1;
  }

  // 删掉满 challengePaceKeepWeeks 周的计数，返回删了几行。
  deleteOld(now: number, limit: number) {
    return this.rows.deleteBefore(weekOf(now - challengePaceKeepWeeks * 7 * 86400_000), limit);
  }
}
