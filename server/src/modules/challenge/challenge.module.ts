import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccountModule } from 'src/modules/account/account.module';
import { ChallengeController } from 'src/modules/challenge/challenge.controller';
import { ChallengeBestEntity, ChallengeRunEntity } from 'src/modules/challenge/challenge.entity';
import { ChallengeRepository, TypeormChallengeRepository } from 'src/modules/challenge/challenge.repository';
import { ChallengeService } from 'src/modules/challenge/challenge.service';
import { ChallengeTasks } from 'src/modules/challenge/challenge.tasks';
import { ChallengeContent } from 'src/modules/challenge/challenge_content';
import { DeviceModule } from 'src/modules/device/device.module';
import { PointsModule } from 'src/modules/points/points.module';

// 挑战：借账号模块认人、随账号删除，结算时调积分模块记一笔；内容（配置与题库）从发布目录热加载；判定在 judges 下，从客户端 Dart 规则移植。
@Module({
  imports: [TypeOrmModule.forFeature([ChallengeRunEntity, ChallengeBestEntity]), DeviceModule, AccountModule, PointsModule],
  controllers: [ChallengeController],
  providers: [{ provide: ChallengeRepository, useClass: TypeormChallengeRepository }, ChallengeContent, ChallengeService, ChallengeTasks],
})
export class ChallengeModule {}
