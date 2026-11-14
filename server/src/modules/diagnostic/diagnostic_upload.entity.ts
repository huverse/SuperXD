import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 认领到应用账号的诊断包（人工决策见客户端 lib/domain/diagnostic_upload.dart）：只记认领过的，随包到期、用户删除或注销账号删除。
@Entity('diagnostic_upload')
export class DiagnosticUploadEntity extends BaseEntity {
  @Column({ name: 'diagnostic_id', type: 'char', length: 8 }) diagnosticId: string;
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'bytes', type: 'int', unsigned: true }) bytes: number;
}
