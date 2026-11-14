import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';

import { DiagnosticUploadEntity } from 'src/modules/diagnostic/diagnostic_upload.entity';

export type DiagnosticUploadRow = { diagnosticId: string; bytes: number; createTime: Date };

// 诊断包认领记录的存储端口：服务只依赖这个抽象。
export abstract class DiagnosticUploadRepository {
  // 把这个包记到账号下；已记在这个账号下算成功，已属于别的账号返回 false。
  abstract claim(diagnosticId: string, accountId: string, bytes: number, now: Date): Promise<boolean>;
  // 这个账号认领过的包，从新到旧，最多 limit 个。
  abstract list(accountId: string, limit: number): Promise<DiagnosticUploadRow[]>;
  // 删掉这个账号下的这条记录，返回是否删了（不是这个账号的不动）。
  abstract remove(accountId: string, diagnosticId: string): Promise<boolean>;
  // 包到期删掉了：记录一并删。
  abstract forget(diagnosticIds: string[]): Promise<void>;
  // 删最多 limit 条认领早于 before 的（文件已经到期，兜底清没对上的记录），返回删了几条。
  abstract deleteBefore(before: Date, limit: number): Promise<number>;
  // 注销账号：在调用方事务里删掉这些账号的记录，返回它们的诊断编号（调用方随后删文件）。
  abstract deleteAccounts(manager: EntityManager, accountIds: string[]): Promise<string[]>;
}

@Injectable()
export class TypeormDiagnosticUploadRepository extends DiagnosticUploadRepository {
  constructor(@InjectRepository(DiagnosticUploadEntity) private readonly uploads: Repository<DiagnosticUploadEntity>) {
    super();
  }

  async claim(diagnosticId: string, accountId: string, bytes: number, now: Date) {
    await this.uploads.query('INSERT IGNORE INTO diagnostic_upload (diagnostic_id, account_id, bytes, create_time, update_time) VALUES (?, ?, ?, ?, ?)', [diagnosticId, accountId, bytes, now, now]);
    const rows = (await this.uploads.query('SELECT account_id AS accountId FROM diagnostic_upload WHERE diagnostic_id = ?', [diagnosticId])) as { accountId: string }[];
    return rows[0]?.accountId === accountId;
  }

  async list(accountId: string, limit: number) {
    return (await this.uploads.query('SELECT diagnostic_id AS diagnosticId, bytes, create_time AS createTime FROM diagnostic_upload WHERE account_id = ? ORDER BY id DESC LIMIT ?', [accountId, limit])) as DiagnosticUploadRow[];
  }

  async remove(accountId: string, diagnosticId: string) {
    const result = (await this.uploads.query('DELETE FROM diagnostic_upload WHERE diagnostic_id = ? AND account_id = ?', [diagnosticId, accountId])) as { affectedRows: number };
    return result.affectedRows > 0;
  }

  async forget(diagnosticIds: string[]) {
    for (let start = 0; start < diagnosticIds.length; start += 1000) {
      await this.uploads.query('DELETE FROM diagnostic_upload WHERE diagnostic_id IN (?)', [diagnosticIds.slice(start, start + 1000)]);
    }
  }

  async deleteBefore(before: Date, limit: number) {
    const result = (await this.uploads.query('DELETE FROM diagnostic_upload WHERE create_time < ? ORDER BY create_time LIMIT ?', [before, limit])) as { affectedRows: number };
    return result.affectedRows;
  }

  async deleteAccounts(manager: EntityManager, accountIds: string[]) {
    if (accountIds.length === 0) return [];
    const rows = (await manager.query('SELECT diagnostic_id AS diagnosticId FROM diagnostic_upload WHERE account_id IN (?)', [accountIds])) as { diagnosticId: string }[];
    await manager.query('DELETE FROM diagnostic_upload WHERE account_id IN (?)', [accountIds]);
    return rows.map((row) => row.diagnosticId);
  }
}
