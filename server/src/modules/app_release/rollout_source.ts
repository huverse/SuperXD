import { readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { Injectable, Logger } from '@nestjs/common';
import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';

import { env } from 'src/config/env';
import { pointsLevelCount, rolloutFileMaxBytes } from 'src/common/relay_limits';
import * as dtos from 'src/modules/app_release/app_release.dto';

// 等级门槛：正好六档、从 0 起、严格递增（与客户端 decodeRolloutConfig 同一规则）。
const levelsValid = (levels: number[]) => levels.length === pointsLevelCount && levels[0] === 0 && levels.every((value, index) => index === 0 || value > levels[index - 1]);

// 灰度配置（人工决策见客户端 lib/domain/rollout.dart）：发布目录里的 rollout.json，由流水线签好上传；公开接口原样透传，
// 积分等级的门槛（levels）也在这里，服务端算等级读同一份。按修改时间与大小缓存，换文件即生效。
@Injectable()
export class RolloutSource {
  private readonly logger = new Logger('RolloutSource');
  private cache: { mtimeMs: number; size: number; config: dtos.RolloutConfigDto } | undefined;

  // 还没放文件时给空开关、信封为空（客户端按各开关的默认值）；文件写坏了抛错，不往外发。
  async current(): Promise<dtos.RolloutConfigDto> {
    const path = join(env().releasesDir, 'rollout.json');
    let info: Awaited<ReturnType<typeof stat>>;
    try {
      info = await stat(path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      this.cache = undefined;
      return { flags: [], envelope: null };
    }
    const cached = this.cache;
    if (cached !== undefined && cached.mtimeMs === info.mtimeMs && cached.size === info.size) return cached.config;
    if (info.size > rolloutFileMaxBytes) throw new Error(`rollout.json 超过 ${rolloutFileMaxBytes} 字节`);
    const file = plainToInstance(dtos.RolloutConfigDto, JSON.parse(await readFile(path, 'utf8')) as object);
    const errors = validateSync(file, { whitelist: true, forbidNonWhitelisted: true });
    if (errors.length > 0) throw new Error(`rollout.json 格式不对：${errors.map((item) => item.property).join(',')}`);
    if (file.levels !== undefined && !levelsValid(file.levels)) throw new Error('rollout.json 的 levels 要是从 0 起严格递增的六个数');
    // 原样透传：class-transformer 会给没写的可选字段补 undefined，序列化时自然省掉，信封里的载荷字节不经这里改动。
    const config = { flags: file.flags, levels: file.levels, envelope: file.envelope ?? null };
    this.cache = { mtimeMs: info.mtimeMs, size: info.size, config };
    this.logger.log(`[RolloutSource] action=load flags=${config.flags.length} levels=${config.levels?.length ?? 0} signed=${config.envelope !== null}`);
    return config;
  }

  // 积分等级的门槛：还没放配置或没写 levels 时为空（人人 Lv0）；配置读不了时记错误、同样按空算，不挡积分与抽奖。
  async levels(): Promise<number[]> {
    try {
      return (await this.current()).levels ?? [];
    } catch (error) {
      console.error(error);
      this.logger.error(`[RolloutSource] action=levels errorType=${error instanceof Error ? error.constructor.name : typeof error}`);
      return [];
    }
  }
}
