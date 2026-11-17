import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';

import { AppHealthDailyEntity } from 'src/modules/app_health/app_health.entity';
import { HealthSample } from 'src/modules/app_health/app_health_rules';

// 健康回报、暂停与意见的存储端口：服务只依赖这个抽象。
export abstract class AppHealthRepository {
  // 累加一份回报（渠道、平台、版本、日唯一，ON DUPLICATE KEY 原子加一）。
  abstract addReport(channel: string, platform: string, versionCode: number, day: string, fatal: boolean, now: Date): Promise<void>;
  abstract addFeedback(channel: string, platform: string, versionCode: number, good: boolean, text: string, now: Date): Promise<void>;
  // 有回报的渠道（最近 sinceDay 起）。
  abstract channelsSince(sinceDay: string): Promise<string[]>;
  // 这个渠道最近 sinceDay 起各版本的份数与致命份数（走 uk_health_day 的前缀，行数是版本数乘天数乘平台数）。
  abstract samplesSince(channel: string, sinceDay: string): Promise<HealthSample[]>;
  // 记一条暂停；这一版已有记录（停着或已解除）就不动，返回有没有新记。
  abstract pause(channel: string, versionCode: number, reason: string, now: Date): Promise<boolean>;
  // 停着的版本（暂停表很小：每次自动暂停一行）。
  abstract pausedVersions(): Promise<{ channel: string; versionCode: number }[]>;
  // 删 before 之前的汇总与意见、pauseBefore 之前的暂停记录，各最多 limit 行，返回删的行数。
  abstract deleteOld(beforeDay: string, before: Date, pauseBefore: Date, limit: number): Promise<number>;
}

@Injectable()
export class TypeormAppHealthRepository extends AppHealthRepository {
  constructor(@InjectRepository(AppHealthDailyEntity) private readonly daily: Repository<AppHealthDailyEntity>) {
    super();
  }

  async addReport(channel: string, platform: string, versionCode: number, day: string, fatal: boolean, now: Date) {
    await this.daily.query(
      'INSERT INTO app_health_daily (channel, platform, version_code, day, reports, fatal, create_time, update_time) VALUES (?, ?, ?, ?, 1, ?, ?, ?) ' +
        'ON DUPLICATE KEY UPDATE reports = reports + 1, fatal = fatal + VALUES(fatal), update_time = VALUES(update_time)',
      [channel, platform, versionCode, day, fatal ? 1 : 0, now, now],
    );
  }

  async addFeedback(channel: string, platform: string, versionCode: number, good: boolean, text: string, now: Date) {
    await this.daily.query('INSERT INTO app_feedback (channel, platform, version_code, good, text, create_time, update_time) VALUES (?, ?, ?, ?, ?, ?, ?)', [channel, platform, versionCode, good ? 1 : 0, text, now, now]);
  }

  async channelsSince(sinceDay: string) {
    const rows = (await this.daily.query('SELECT DISTINCT channel FROM app_health_daily WHERE day >= ? LIMIT 50', [sinceDay])) as { channel: string }[];
    return rows.map((row) => row.channel);
  }

  async samplesSince(channel: string, sinceDay: string) {
    const rows = (await this.daily.query(
      'SELECT version_code AS versionCode, SUM(reports) AS reports, SUM(fatal) AS fatal FROM app_health_daily WHERE channel = ? AND day >= ? GROUP BY version_code ORDER BY version_code DESC LIMIT 20',
      [channel, sinceDay],
    )) as { versionCode: number; reports: string; fatal: string }[];
    return rows.map((row) => ({ versionCode: Number(row.versionCode), reports: Number(row.reports), fatal: Number(row.fatal) }));
  }

  async pause(channel: string, versionCode: number, reason: string, now: Date) {
    const result = (await this.daily.query('INSERT IGNORE INTO app_release_pause (channel, version_code, paused, reason, create_time, update_time) VALUES (?, ?, 1, ?, ?, ?)', [
      channel,
      versionCode,
      reason,
      now,
      now,
    ])) as { affectedRows: number };
    return result.affectedRows > 0;
  }

  async pausedVersions() {
    const rows = (await this.daily.query('SELECT channel, version_code AS versionCode FROM app_release_pause WHERE paused = 1 ORDER BY id DESC LIMIT 50')) as { channel: string; versionCode: number }[];
    return rows.map((row) => ({ channel: row.channel, versionCode: Number(row.versionCode) }));
  }

  async deleteOld(beforeDay: string, before: Date, pauseBefore: Date, limit: number) {
    const daily = (await this.daily.query('DELETE FROM app_health_daily WHERE day < ? LIMIT ?', [beforeDay, limit])) as { affectedRows: number };
    const feedback = (await this.daily.query('DELETE FROM app_feedback WHERE create_time < ? LIMIT ?', [before, limit])) as { affectedRows: number };
    const pauses = (await this.daily.query('DELETE FROM app_release_pause WHERE create_time < ? LIMIT ?', [pauseBefore, limit])) as { affectedRows: number };
    return daily.affectedRows + feedback.affectedRows + pauses.affectedRows;
  }
}
