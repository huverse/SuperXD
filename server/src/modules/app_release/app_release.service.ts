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
import { appDownloadsPerInstance, appFilePerHour, appReleaseFileMaxBytes, appReleasePerHour } from 'src/common/relay_limits';
import * as dtos from 'src/modules/app_release/app_release.dto';

// 应用更新：发版时把清单（<渠道>.json）与各架构安装包放进 RELAY_RELEASES_DIR，这里只读不写。
// 不签名、不碰数据库：清单是公开信息，安装包的真伪由客户端核对 SHA-256 与签名证书（与已装应用一致才装）。
@Injectable()
export class AppReleaseService {
  private readonly logger = new Logger('AppRelease');
  // 按渠道缓存解析好的清单，文件的修改时间或大小变了才重读；只缓存目录里真实存在的文件，条目数有界。
  private readonly cache = new Map<string, { mtimeMs: number; size: number; release: dtos.AppReleaseFile }>();
  private downloads = 0;

  constructor(private readonly limiter: RateLimiter) {}

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
    };
  }

  // 交给 express 的 sendFile：支持 Range 断点续传与条件请求，按流发送不占内存；根目录限定在发布目录。
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
      response.sendFile(name, { root: env().releasesDir, dotfiles: 'deny', headers: { 'Content-Type': 'application/vnd.android.package-archive' } }, resolve),
    );
    if (error === undefined) return;
    // 已开始发送后出错多是客户端断开（暂停、切网），无从再回错误。
    if (response.headersSent) {
      this.logger.debug(`[AppRelease] action=send_aborted file=${name} errorType=${error.code ?? error.constructor.name}`);
      return;
    }
    if (error.status === HttpStatus.NOT_FOUND) throw new RelayError(RelayCode.releaseNotFound, HttpStatus.NOT_FOUND, '安装包不存在');
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
    this.logger.log(`[AppRelease] action=load channel=${channel} versionCode=${release.versionCode}`);
    return release;
  }
}
