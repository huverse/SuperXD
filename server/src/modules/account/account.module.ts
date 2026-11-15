import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccountController } from 'src/modules/account/account.controller';
import { AccountDeviceEntity, AccountTombstoneEntity, AppAccountEntity } from 'src/modules/account/account.entity';
import { AccountRepository, TypeormAccountRepository } from 'src/modules/account/account.repository';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';
import { AccountKeys } from 'src/modules/account/account_keys';
import { AccountRetentionTask } from 'src/modules/account/account_retention.task';
import { AccountService } from 'src/modules/account/account.service';
import { DeviceModule } from 'src/modules/device/device.module';
import { IpRegion } from 'src/common/ip_region';
import { env } from 'src/config/env';

// 应用账号：借设备模块验签与登记密钥，设备模块不知道账号。设备删除时的连带删除由 pairing 编排。
// 积分、挑战、解锁、私信、诊断包与节日抽奖依赖本模块按设备认账号（AccountRepository.accountOf），删账号时除抽签记录外它们的数据经 AccountDataHooks 一起删。
@Module({
  imports: [TypeOrmModule.forFeature([AppAccountEntity, AccountDeviceEntity, AccountTombstoneEntity]), DeviceModule],
  controllers: [AccountController],
  providers: [
    { provide: AccountRepository, useClass: TypeormAccountRepository },
    // 扫码登录查属地的离线库，路径取 env（没配就查不出），一个实例一份。
    { provide: IpRegion, useFactory: () => new IpRegion(env().ipRegionDb) },
    AccountKeys,
    AccountDataHooks,
    AccountService,
    AccountRetentionTask,
  ],
  exports: [AccountRepository, AccountDataHooks],
})
export class AccountModule {}
