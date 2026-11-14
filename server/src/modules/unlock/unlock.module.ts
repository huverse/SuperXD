import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccountModule } from 'src/modules/account/account.module';
import { AppReleaseModule } from 'src/modules/app_release/app_release.module';
import { DeviceModule } from 'src/modules/device/device.module';
import { PointsModule } from 'src/modules/points/points.module';
import { UnlockController } from 'src/modules/unlock/unlock.controller';
import { AccountUnlockEntity } from 'src/modules/unlock/unlock.entity';
import { TypeormUnlockRepository, UnlockRepository } from 'src/modules/unlock/unlock.repository';
import { UnlockService } from 'src/modules/unlock/unlock.service';
import { UnlockTask } from 'src/modules/unlock/unlock.task';

// 解锁（隐藏服务与新游戏抢先玩，规则见 unlock_rules.ts）：借账号模块认人、随账号删除，借积分模块花积分、退回与算等级，配置读发布模块的灰度配置。
@Module({
  imports: [TypeOrmModule.forFeature([AccountUnlockEntity]), DeviceModule, AccountModule, PointsModule, AppReleaseModule],
  controllers: [UnlockController],
  providers: [{ provide: UnlockRepository, useClass: TypeormUnlockRepository }, UnlockService, UnlockTask],
})
export class UnlockModule {}
