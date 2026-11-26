import { readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';
import type { Response } from 'express';

import { env } from 'src/config/env';
import { rateSubjectOf } from 'src/common/client_ip';
import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { appDownloadsPerInstance, appFilePerHour, appReleaseFileMaxBytes, appReleasePerHour, cinemaFileMaxBytes, cinemaRulesPerHour, developerNotesFileMaxBytes, developerNotesPerHour, rolloutConfigPerHour } from 'src/common/relay_limits';
import { AppHealthService } from 'src/modules/app_health/app_health.service';
import { ConfigRevision } from 'src/modules/app_release/config_revision';
import { RolloutSource } from 'src/modules/app_release/rollout_source';
import * as dtos from 'src/modules/app_release/app_release.dto';

// 应用更新：发版时把清单（<渠道>.json）与各架构安装包放进 RELAY_RELEASES_DIR，这里只读不写。
// 不碰数据库：清单是公开信息，安装包的真伪由客户端核对 SHA-256 与签名证书（与已装应用一致才装）。
// 清单与开发者的话由流水线签好名（人工决策见客户端 lib/device/signed_content.dart），这里不签、不验，只把信封原样透传；
// 明文字段照旧给 1.0.0-alpha.15 及以前不验签的旧客户端。返回里总带 envelope（文件里没有时为 null），流水线上传前靠它确认中转已能透传。
@Injectable()
export class AppReleaseService {
  private readonly logger = new Logger('AppRelease');
  // 按渠道缓存解析好的清单，文件的修改时间或大小变了才重读；只缓存目录里真实存在的文件，条目数有界。
  private readonly cache = new Map<string, { mtimeMs: number; size: number; release: dtos.AppReleaseFile }>();
  // 开发者的话同样按修改时间与大小缓存，只有一份。
  private notesCache: { mtimeMs: number; size: number; notes: dtos.DeveloperNotesDto } | undefined;
  private cinemaCache: { mtimeMs: number; size: number; rules: dtos.CinemaRulesDto } | undefined;
  private downloads = 0;

  constructor(
    private readonly limiter: RateLimiter,
    private readonly rollouts: RolloutSource,
    private readonly health: AppHealthService,
    private readonly revision: ConfigRevision,
  ) {}

  async latest(ip: string, channel: string, abi: dtos.AppReleaseQueryDto['abi']): Promise<dtos.AppReleaseDto> {
    const retryAfter = await this.limiter.hit('app_release', rateSubjectOf(ip), appReleasePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '检查更新过于频繁', { retryAfter });
    const release = await this.load(channel);
    if (release === null) throw new RelayError(RelayCode.releaseNotFound, HttpStatus.NOT_FOUND, '这个渠道没有发布版本');
    const apk = release.apks.find((item) => item.abi === abi);
    return {
      versionCode: release.versionCode,
      versionName: release.versionName,
      publishedAt: release.publishedAt,
      minSupportedVersionCode: release.minSupportedVersionCode,
      notes: release.notes,
      releasePage: release.releasePage,
      apk: apk === undefined ? null : { url: `/v1/app/files/${apk.file}`, size: apk.size, sha256: apk.sha256 },
      envelope: release.envelopes?.[abi] ?? null,
    };
  }

  // 开发者的话：发布目录里的 developer_notes.json，还没放时给空列表、信封为空（客户端什么也不显示）。
  async notes(ip: string): Promise<dtos.DeveloperNotesDto> {
    const retryAfter = await this.limiter.hit('developer_notes', rateSubjectOf(ip), developerNotesPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '请求过于频繁', { retryAfter });
    const path = join(env().releasesDir, 'developer_notes.json');
    let info: Awaited<ReturnType<typeof stat>>;
    try {
      info = await stat(path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      this.notesCache = undefined;
      return { notes: [], envelope: null };
    }
    const cached = this.notesCache;
    if (cached !== undefined && cached.mtimeMs === info.mtimeMs && cached.size === info.size) return cached.notes;
    if (info.size > developerNotesFileMaxBytes) throw new Error(`developer_notes.json 超过 ${developerNotesFileMaxBytes} 字节`);
    const file = plainToInstance(dtos.DeveloperNotesDto, JSON.parse(await readFile(path, 'utf8')) as object);
    const errors = validateSync(file, { whitelist: true, forbidNonWhitelisted: true });
    if (errors.length > 0) throw new Error(`developer_notes.json 格式不对：${errors.map((item) => item.property).join(',')}`);
    const notes = { notes: file.notes, envelope: file.envelope ?? null };
    this.notesCache = { mtimeMs: info.mtimeMs, size: info.size, notes };
    this.logger.log(`[AppRelease] action=load_notes count=${notes.notes.length} signed=${notes.envelope !== null}`);
    return notes;
  }

  // 条件请求（人工决策见 config_revision.ts）：回复带 ETag（公共配置的版本号），带着它来、没变就回 304，不读文件、不计限流
  // （校园网一个出口后面人多，回到前台都来核对一次）。版本号还没算出来时不带 ETag、照常回全量。
  private unchanged(known: string | undefined, response: Response) {
    const revision = this.revision.value;
    if (revision === null) return false;
    response.setHeader('ETag', `"${revision}"`);
    if (known !== `"${revision}"`) return false;
    response.status(HttpStatus.NOT_MODIFIED);
    return true;
  }

  // 灰度配置：读法见 RolloutSource（积分等级的门槛也从那里读）。
  async rollout(ip: string, known?: string, response?: Response): Promise<dtos.RolloutConfigDto | undefined> {
    if (response !== undefined && this.unchanged(known, response)) return undefined;
    const retryAfter = await this.limiter.hit('app_rollout', rateSubjectOf(ip), rolloutConfigPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '请求过于频繁', { retryAfter });
    return this.rollouts.current();
  }

  // 第 2 版灰度配置：读法见 RolloutSource.flags，与第 1 版共用限流。
  async flags(ip: string, known?: string, response?: Response): Promise<dtos.FlagConfigResponseDto | undefined> {
    if (response !== undefined && this.unchanged(known, response)) return undefined;
    const retryAfter = await this.limiter.hit('app_rollout', rateSubjectOf(ip), rolloutConfigPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '请求过于频繁', { retryAfter });
    const [config, paused] = await Promise.all([this.rollouts.flags(), this.health.paused()]);
    return { ...config, paused };
  }

  // 电影院的片源规则包：发布目录里的 cinema.json，只核外形与大小、原样透传；还没放时信封为空（客户端照旧用本机缓存的）。按修改时间与大小缓存，换文件即生效。
  async cinema(ip: string): Promise<dtos.CinemaRulesDto> {
    const retryAfter = await this.limiter.hit('app_cinema', rateSubjectOf(ip), cinemaRulesPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '请求过于频繁', { retryAfter });
    const path = join(env().releasesDir, 'cinema.json');
    let info: Awaited<ReturnType<typeof stat>>;
    try {
      info = await stat(path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      this.cinemaCache = undefined;
      return { version: 1, envelope: null };
    }
    const cached = this.cinemaCache;
    if (cached !== undefined && cached.mtimeMs === info.mtimeMs && cached.size === info.size) return cached.rules;
    if (info.size > cinemaFileMaxBytes) throw new Error(`cinema.json 超过 ${cinemaFileMaxBytes} 字节`);
    const file = plainToInstance(dtos.CinemaRulesDto, JSON.parse(await readFile(path, 'utf8')) as object);
    const errors = validateSync(file, { whitelist: true, forbidNonWhitelisted: true });
    if (errors.length > 0 || file.envelope === null || file.envelope === undefined) throw new Error(`cinema.json 格式不对：${errors.map((item) => item.property).join(',')}`);
    const rules = { version: 1 as const, envelope: file.envelope };
    this.cinemaCache = { mtimeMs: info.mtimeMs, size: info.size, rules };
    this.logger.log('[AppRelease] action=load_cinema signed=true');
    return rules;
  }

  // 交给 express 的 sendFile：支持 Range 断点续传与条件请求，按流发送不占内存；根目录限定在发布目录。安装包、字体包与星空素材共用同一套限流与同时下载上限，按扩展名给类型。
  async send(ip: string, name: string, response: Response): Promise<void> {
    const retryAfter = await this.limiter.hit('app_file', rateSubjectOf(ip), appFilePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '下载过于频繁', { retryAfter });
    if (this.downloads >= appDownloadsPerInstance) {
      throw new RelayError(RelayCode.rateLimited, HttpStatus.SERVICE_UNAVAILABLE, '同时下载的人太多', { retryAfter: 60 });
    }
    this.downloads++;
    response.once('close', () => this.downloads--);
    this.logger.debug(`[AppRelease] action=send file=${name} active=${this.downloads}`);
    const error = await new Promise<(Error & { status?: number; code?: string }) | undefined>((resolve) =>
      response.sendFile(name, { root: env().releasesDir, dotfiles: 'deny', headers: { 'Content-Type': contentTypeOf(name) } }, resolve),
    );
    if (error === undefined) return;
    // 已开始发送后出错多是客户端断开（暂停、切网），无从再回错误。
    if (response.headersSent) {
      this.logger.debug(`[AppRelease] action=send_aborted file=${name} errorType=${error.code ?? error.constructor.name}`);
      return;
    }
    if (error.status === HttpStatus.NOT_FOUND) throw new RelayError(RelayCode.releaseNotFound, HttpStatus.NOT_FOUND, '文件不存在');
    throw error;
  }

  private async load(channel: string): Promise<dtos.AppReleaseFile | null> {
    const path = join(env().releasesDir, `${channel}.json`);
    let info: Awaited<ReturnType<typeof stat>>;
    try {
      info = await stat(path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      this.cache.delete(channel);
      return null;
    }
    const cached = this.cache.get(channel);
    if (cached !== undefined && cached.mtimeMs === info.mtimeMs && cached.size === info.size) return cached.release;
    if (info.size > appReleaseFileMaxBytes) throw new Error(`清单 ${channel}.json 超过 ${appReleaseFileMaxBytes} 字节`);
    const release = plainToInstance(dtos.AppReleaseFile, JSON.parse(await readFile(path, 'utf8')) as object);
    const errors = validateSync(release, { whitelist: true, forbidNonWhitelisted: true });
    if (errors.length > 0) throw new Error(`清单 ${channel}.json 格式不对：${errors.map((item) => item.property).join(',')}`);
    this.cache.set(channel, { mtimeMs: info.mtimeMs, size: info.size, release });
    this.logger.log(`[AppRelease] action=load channel=${channel} versionCode=${release.versionCode} signed=${release.envelopes !== undefined}`);
    return release;
  }
}

// 下载文件按扩展名给类型（文件名已由 AppFileParamDto 限定为 .apk、.ttf 或 .webp）。
function contentTypeOf(name: string): string {
  if (name.endsWith('.ttf')) return 'font/ttf';
  if (name.endsWith('.webp')) return 'image/webp';
  return 'application/vnd.android.package-archive';
}
