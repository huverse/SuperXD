import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccountModule } from 'src/modules/account/account.module';
import { DeviceModule } from 'src/modules/device/device.module';
import { PointsModule } from 'src/modules/points/points.module';
import { PassController } from 'src/modules/pass/pass.controller';
import { AccountPassEntity } from 'src/modules/pass/pass.entity';
import { PassRepository, TypeormPassRepository } from 'src/modules/pass/pass.repository';
import { PassService } from 'src/modules/pass/pass.service';
import { PassTask } from 'src/modules/pass/pass.task';

// 积分时长券（规则见 pass.service.ts）：借账号模块认人、随账号删除，借积分模块花积分。
@Module({
  imports: [TypeOrmModule.forFeature([AccountPassEntity]), DeviceModule, AccountModule, PointsModule],
  controllers: [PassController],
  providers: [{ provide: PassRepository, useClass: TypeormPassRepository }, PassService, PassTask],
  exports: [PassService],
})
export class PassModule {}
