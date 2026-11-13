import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccountController } from 'src/modules/account/account.controller';
import { AccountDeviceEntity, AccountIdentityEntity, AppAccountEntity } from 'src/modules/account/account.entity';
import { AccountRepository, TypeormAccountRepository } from 'src/modules/account/account.repository';
import { AccountKeys } from 'src/modules/account/account_keys';
import { ACCOUNT_PROVIDERS, KingoAccountProvider } from 'src/modules/account/account_provider';
import { AccountRetentionTask } from 'src/modules/account/account_retention.task';
import { AccountService } from 'src/modules/account/account.service';
import { DeviceModule } from 'src/modules/device/device.module';
import { KingoModule } from 'src/modules/kingo/kingo.module';

// 应用账号：借设备模块验签与登记密钥，借教务模块代登录；设备与教务模块都不知道账号。设备删除时的连带删除由 pairing 编排。
@Module({
  imports: [TypeOrmModule.forFeature([AppAccountEntity, AccountIdentityEntity, AccountDeviceEntity]), DeviceModule, KingoModule],
  controllers: [AccountController],
  providers: [
    { provide: AccountRepository, useClass: TypeormAccountRepository },
    AccountKeys,
    KingoAccountProvider,
    { provide: ACCOUNT_PROVIDERS, useFactory: (kingo: KingoAccountProvider) => [kingo], inject: [KingoAccountProvider] },
    AccountService,
    AccountRetentionTask,
  ],
  exports: [AccountRepository],
})
export class AccountModule {}
