import { Module } from '@nestjs/common';

import { AppReleaseController } from 'src/modules/app_release/app_release.controller';
import { AppReleaseService } from 'src/modules/app_release/app_release.service';
import { RolloutSource } from 'src/modules/app_release/rollout_source';

// 应用更新、开发者的话与灰度配置；灰度配置的读取 RolloutSource 也给积分模块读等级门槛。
@Module({
  controllers: [AppReleaseController],
  providers: [AppReleaseService, RolloutSource],
  exports: [RolloutSource],
})
export class AppReleaseModule {}
