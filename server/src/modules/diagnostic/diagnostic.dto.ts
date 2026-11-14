import { ApiProperty } from '@nestjs/swagger';
import { Matches } from 'class-validator';

export class DiagnosticReceiptDto {
  @ApiProperty({ description: '诊断编号：8 位 Crockford base32，也是服务器上的文件名；用户把它告诉开发者，要提前删除也凭它' }) id: string;
  @ApiProperty({ description: '服务器保存的天数，到期自动删除' }) keepDays: number;
  @ApiProperty({ description: '认领口令：16 字节随机数的 base64url，一天内凭它把这个包认领到应用账号下，只能用一次' }) claim: string;
}

export class DiagnosticIdParamDto {
  @ApiProperty({ description: '诊断编号' }) @Matches(/^[0-9A-HJKMNP-TV-Z]{8}$/) id: string;
}

export class DiagnosticClaimBodyDto {
  @ApiProperty({ description: '上传回执里的认领口令' }) @Matches(/^[A-Za-z0-9_-]{22}$/) claim: string;
}

export class DiagnosticUploadDto {
  @ApiProperty({ description: '诊断编号' }) id: string;
  @ApiProperty({ description: '密文大小，字节' }) bytes: number;
  @ApiProperty({ description: '认领时刻（上传后紧接着），毫秒' }) uploadedAt: number;
  @ApiProperty({ description: '大约什么时候删除，毫秒' }) expiresAt: number;
}

export class DiagnosticUploadListDto {
  @ApiProperty({ type: [DiagnosticUploadDto], description: '从新到旧，最多 50 个' }) uploads: DiagnosticUploadDto[];
}
