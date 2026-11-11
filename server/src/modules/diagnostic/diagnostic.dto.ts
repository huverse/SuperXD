import { ApiProperty } from '@nestjs/swagger';

export class DiagnosticReceiptDto {
  @ApiProperty({ description: '诊断编号：8 位 Crockford base32，也是服务器上的文件名；用户把它告诉开发者，要提前删除也凭它' }) id: string;
  @ApiProperty({ description: '服务器保存的天数，到期自动删除' }) keepDays: number;
}
