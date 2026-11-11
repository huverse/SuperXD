import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { DeviceModule } from 'src/modules/device/device.module';
import { RewardController } from 'src/modules/reward/reward.controller';
import { RewardCampaignEntity, RewardDrawEntity, RewardPrizeEntity } from 'src/modules/reward/reward.entity';
import { RewardRepository, TypeormRewardRepository } from 'src/modules/reward/reward.repository';
import { RewardRetentionTask } from 'src/modules/reward/reward_retention.task';
import { RewardDice, RewardService } from 'src/modules/reward/reward.service';

// 抽签接口挂设备签名（DeviceAuthGuard），只依赖设备模块验签；设备模块不知道抽奖。
@Module({
  imports: [TypeOrmModule.forFeature([RewardCampaignEntity, RewardPrizeEntity, RewardDrawEntity]), DeviceModule],
  controllers: [RewardController],
  providers: [{ provide: RewardRepository, useClass: TypeormRewardRepository }, RewardService, RewardDice, RewardRetentionTask],
})
export class RewardModule {}
