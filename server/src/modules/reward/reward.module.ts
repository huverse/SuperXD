import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { RewardController } from 'src/modules/reward/reward.controller';
import { RewardCampaignEntity, RewardDrawEntity, RewardPrizeEntity } from 'src/modules/reward/reward.entity';
import { RewardRepository, TypeormRewardRepository } from 'src/modules/reward/reward.repository';
import { RewardRetentionTask } from 'src/modules/reward/reward_retention.task';
import { RewardDice, RewardService } from 'src/modules/reward/reward.service';

@Module({
  imports: [TypeOrmModule.forFeature([RewardCampaignEntity, RewardPrizeEntity, RewardDrawEntity])],
  controllers: [RewardController],
  providers: [{ provide: RewardRepository, useClass: TypeormRewardRepository }, RewardService, RewardDice, RewardRetentionTask],
})
export class RewardModule {}
