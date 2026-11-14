import { Body, Controller, Delete, Get, HttpCode, Param, Post, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { DiagnosticAccountService } from 'src/modules/diagnostic/diagnostic_account.service';
import * as dtos from 'src/modules/diagnostic/diagnostic.dto';

// 应用账号下的诊断包：用应用账号的设备密钥签名，认领刚传的包、看与删自己认领过的（人工决策见客户端 lib/domain/diagnostic_upload.dart）。
@ApiTags('diagnostic')
@Controller('v1/account/diagnostics')
@UseGuards(DeviceAuthGuard)
export class DiagnosticAccountController {
  constructor(private readonly diagnostics: DiagnosticAccountService) {}

  @Post(':id/claim')
  @HttpCode(200)
  claim(@CurrentDevice() deviceId: string, @Param() param: dtos.DiagnosticIdParamDto, @Body() body: dtos.DiagnosticClaimBodyDto): Promise<dtos.DiagnosticUploadDto> {
    return this.diagnostics.claim(deviceId, param.id, body.claim);
  }

  @Get()
  list(@CurrentDevice() deviceId: string): Promise<dtos.DiagnosticUploadListDto> {
    return this.diagnostics.list(deviceId);
  }

  @Delete(':id')
  @HttpCode(204)
  remove(@CurrentDevice() deviceId: string, @Param() param: dtos.DiagnosticIdParamDto) {
    return this.diagnostics.remove(deviceId, param.id);
  }
}
