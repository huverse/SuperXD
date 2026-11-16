import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AppHealthController } from 'src/modules/app_health/app_health.controller';
import { AppFeedbackEntity, AppHealthDailyEntity, AppReleasePauseEntity } from 'src/modules/app_health/app_health.entity';
import { AppHealthRepository, TypeormAppHealthRepository } from 'src/modules/app_health/app_health.repository';
import { AppHealthService } from 'src/modules/app_health/app_health.service';
import { AppHealthTask } from 'src/modules/app_health/app_health.task';

// 分批更新的健康回报、自动暂停与意见反馈（规则见 app_health_rules.ts）；暂停的版本由发布模块的 /v1/app/flags 带出（导出服务给它读）。
@Module({
  imports: [TypeOrmModule.forFeature([AppHealthDailyEntity, AppReleasePauseEntity, AppFeedbackEntity])],
  controllers: [AppHealthController],
  providers: [{ provide: AppHealthRepository, useClass: TypeormAppHealthRepository }, AppHealthService, AppHealthTask],
  exports: [AppHealthService],
})
export class AppHealthModule {}
