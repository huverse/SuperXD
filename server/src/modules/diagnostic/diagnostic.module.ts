import { Module } from '@nestjs/common';

import { DiagnosticController } from 'src/modules/diagnostic/diagnostic.controller';
import { DiagnosticRetentionTask } from 'src/modules/diagnostic/diagnostic_retention.task';
import { DiagnosticService } from 'src/modules/diagnostic/diagnostic.service';
import { DiagnosticStore, FileDiagnosticStore } from 'src/modules/diagnostic/diagnostic.store';

@Module({
  controllers: [DiagnosticController],
  providers: [{ provide: DiagnosticStore, useClass: FileDiagnosticStore }, DiagnosticService, DiagnosticRetentionTask],
})
export class DiagnosticModule {}
