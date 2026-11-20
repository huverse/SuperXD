import { createHash } from 'node:crypto';
import { stat } from 'node:fs/promises';
import { join } from 'node:path';
import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';

import { env } from 'src/config/env';
import { configRevisionRefreshMs } from 'src/common/relay_limits';
import { AppHealthService } from 'src/modules/app_health/app_health.service';

// [人工决策-2026-11-20 15:38:08] 灰度改了立即生效（用户选「版本号随回复下发」，没选长连接推送与只去掉一小时间隔）：
// 中转在每条回复的 x-sxd-config 里带公共灰度配置的版本号（flags.json、rollout.json 的修改时间与大小，加自动暂停的版本），
// 手机看到和本机记的不一样就马上重新取配置；签名请求另在 x-sxd-targets 里带这台设备的点名版本（device_auth.guard.ts，管理命令 flag_admin 点名、撤销时写）。
// 回到前台时手机带上次的版本号来核对，没变回 304，不读文件、不计限流。版本号只是「该重新取了」的信号，配置本身照旧验签，回复头伪造不了开关。
// 由文件与库算出、不存状态，几个实例算出来的一样；每 configRevisionRefreshMs 重算一次，换文件或自动暂停后最迟这么久就变。
@Injectable()
export class ConfigRevision implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger('ConfigRevision');
  private timer: NodeJS.Timeout | undefined;
  // 还没算出来时为空：不带回复头、条件请求一律当变了。
  value: string | null = null;

  constructor(private readonly health: AppHealthService) {}

  async onModuleInit() {
    await this.refresh();
    this.timer = setInterval(() => this.refresh().catch((error) => console.error(error)), configRevisionRefreshMs);
    this.timer.unref();
  }

  onModuleDestroy() {
    clearInterval(this.timer);
  }

  async refresh() {
    const files = await Promise.all(['flags.json', 'rollout.json'].map((name) => this.stamp(name)));
    const paused = [...(await this.health.paused())].sort();
    const next = createHash('sha256').update([...files, ...paused].join('\n')).digest('base64url').slice(0, 16);
    if (next !== this.value) this.logger.log(`[ConfigRevision] action=change revision=${next} paused=${paused.length}`);
    this.value = next;
  }

  private async stamp(name: string) {
    try {
      const info = await stat(join(env().releasesDir, name));
      return `${name}:${info.mtimeMs}:${info.size}`;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      return `${name}:none`;
    }
  }
}
