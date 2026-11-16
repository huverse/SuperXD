import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccountModule } from 'src/modules/account/account.module';
import { DeviceModule } from 'src/modules/device/device.module';
import { PointsModule } from 'src/modules/points/points.module';
import { RewardController } from 'src/modules/reward/reward.controller';
import { RewardAudienceEntity, RewardCampaignEntity, RewardDrawEntity, RewardPrizeEntity } from 'src/modules/reward/reward.entity';
import { RewardRepository, TypeormRewardRepository } from 'src/modules/reward/reward.repository';
import { RewardRetentionTask } from 'src/modules/reward/reward_retention.task';
import { RewardDice, RewardService } from 'src/modules/reward/reward.service';

// 抽签与查状态挂设备签名（DeviceAuthGuard），按设备所在的应用账号认人（人工决策见 reward_odds.ts）；设备与账号模块都不知道抽奖（名单随账号删除经账号的数据钩子）；加权与最低等级借积分模块算等级。
@Module({
  imports: [TypeOrmModule.forFeature([RewardCampaignEntity, RewardPrizeEntity, RewardDrawEntity, RewardAudienceEntity]), DeviceModule, AccountModule, PointsModule],
  controllers: [RewardController],
  providers: [{ provide: RewardRepository, useClass: TypeormRewardRepository }, RewardService, RewardDice, RewardRetentionTask],
})
export class RewardModule {}
