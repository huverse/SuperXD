import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccountModule } from 'src/modules/account/account.module';
import { DeviceModule } from 'src/modules/device/device.module';
import { RewardController } from 'src/modules/reward/reward.controller';
import { RewardCampaignEntity, RewardDrawEntity, RewardPrizeEntity } from 'src/modules/reward/reward.entity';
import { RewardRepository, TypeormRewardRepository } from 'src/modules/reward/reward.repository';
import { RewardRetentionTask } from 'src/modules/reward/reward_retention.task';
import { RewardDice, RewardService } from 'src/modules/reward/reward.service';

// 抽签接口挂设备签名（DeviceAuthGuard），按设备所在的应用账号认人（人工决策见 reward_odds.ts）；设备与账号模块都不知道抽奖。
@Module({
  imports: [TypeOrmModule.forFeature([RewardCampaignEntity, RewardPrizeEntity, RewardDrawEntity]), DeviceModule, AccountModule],
  controllers: [RewardController],
  providers: [{ provide: RewardRepository, useClass: TypeormRewardRepository }, RewardService, RewardDice, RewardRetentionTask],
})
export class RewardModule {}
