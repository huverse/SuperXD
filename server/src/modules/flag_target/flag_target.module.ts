import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccountModule } from 'src/modules/account/account.module';
import { DeviceModule } from 'src/modules/device/device.module';
import { FlagTargetController } from 'src/modules/flag_target/flag_target.controller';
import { RolloutTargetEntity } from 'src/modules/flag_target/flag_target.entity';
import { FlagTargetRepository, TypeormFlagTargetRepository } from 'src/modules/flag_target/flag_target.repository';
import { FlagTargetService } from 'src/modules/flag_target/flag_target.service';
import { FlagTargetTask } from 'src/modules/flag_target/flag_target.task';

// 灰度点名（规则见 flag_target.service.ts）：借账号模块认人、随账号删除；名单由管理命令 flag_admin 写。
@Module({
  imports: [TypeOrmModule.forFeature([RolloutTargetEntity]), DeviceModule, AccountModule],
  controllers: [FlagTargetController],
  providers: [{ provide: FlagTargetRepository, useClass: TypeormFlagTargetRepository }, FlagTargetService, FlagTargetTask],
})
export class FlagTargetModule {}
