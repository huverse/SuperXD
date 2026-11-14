import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccountModule } from 'src/modules/account/account.module';
import { DeviceModule } from 'src/modules/device/device.module';
import { DiagnosticAccountController } from 'src/modules/diagnostic/diagnostic_account.controller';
import { DiagnosticAccountService } from 'src/modules/diagnostic/diagnostic_account.service';
import { DiagnosticController } from 'src/modules/diagnostic/diagnostic.controller';
import { DiagnosticRetentionTask } from 'src/modules/diagnostic/diagnostic_retention.task';
import { DiagnosticService } from 'src/modules/diagnostic/diagnostic.service';
import { DiagnosticStore, FileDiagnosticStore } from 'src/modules/diagnostic/diagnostic.store';
import { DiagnosticUploadEntity } from 'src/modules/diagnostic/diagnostic_upload.entity';
import { DiagnosticUploadRepository, TypeormDiagnosticUploadRepository } from 'src/modules/diagnostic/diagnostic_upload.repository';

// 诊断包：上传免签名、与别的模块无关；认领到应用账号的部分借设备模块验签、借账号模块按设备认账号，注销账号时经 AccountDataHooks 连带删，两者都不知道诊断包。
@Module({
  imports: [TypeOrmModule.forFeature([DiagnosticUploadEntity]), DeviceModule, AccountModule],
  controllers: [DiagnosticController, DiagnosticAccountController],
  providers: [
    { provide: DiagnosticStore, useClass: FileDiagnosticStore },
    { provide: DiagnosticUploadRepository, useClass: TypeormDiagnosticUploadRepository },
    DiagnosticService,
    DiagnosticAccountService,
    DiagnosticRetentionTask,
  ],
})
export class DiagnosticModule {}
