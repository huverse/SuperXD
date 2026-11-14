import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccountModule } from 'src/modules/account/account.module';
import { AppReleaseModule } from 'src/modules/app_release/app_release.module';
import { DeviceModule } from 'src/modules/device/device.module';
import { PointsController } from 'src/modules/points/points.controller';
import { PointsEntryEntity, PointsGrantEntity } from 'src/modules/points/points.entity';
import { PointsRepository, TypeormPointsRepository } from 'src/modules/points/points.repository';
import { PointsRetentionTask } from 'src/modules/points/points_retention.task';
import { PointsService } from 'src/modules/points/points.service';

// 积分账本：借账号模块按设备认账号、随账号删除；获得的来源（挑战等）调 PointsService.grantIn、花费的去处调 spendIn，本模块不知道来源与去处是什么；
// 等级门槛从发布模块的灰度配置读。
@Module({
  imports: [TypeOrmModule.forFeature([PointsGrantEntity, PointsEntryEntity]), DeviceModule, AccountModule, AppReleaseModule],
  controllers: [PointsController],
  providers: [{ provide: PointsRepository, useClass: TypeormPointsRepository }, PointsService, PointsRetentionTask],
  exports: [PointsService],
})
export class PointsModule {}
