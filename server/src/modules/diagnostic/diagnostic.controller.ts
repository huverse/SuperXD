import { Controller, HttpCode, Ip, Post, Req } from '@nestjs/common';
import { ApiBody, ApiConsumes, ApiTags } from '@nestjs/swagger';
import type { Request } from 'express';

import { DiagnosticService } from 'src/modules/diagnostic/diagnostic.service';
import * as dtos from 'src/modules/diagnostic/diagnostic.dto';

// 上传诊断包：请求体是本机加密过的日志包（application/octet-stream），按流写盘、不读进内存。只有这一个接口，没有下载。
@ApiTags('diagnostic')
@Controller('v1/diagnostics')
export class DiagnosticController {
  constructor(private readonly diagnostics: DiagnosticService) {}

  @Post()
  @HttpCode(200)
  @ApiConsumes('application/octet-stream')
  @ApiBody({ description: '诊断包密文：版本(1) | 一次性 X25519 公钥(32) | 随机数(12) | AES-256-GCM 密文 | 标签(16)' })
  upload(@Req() request: Request, @Ip() ip: string): Promise<dtos.DiagnosticReceiptDto> {
    return this.diagnostics.upload(ip, Number(request.headers['content-length']), request);
  }
}
