import { Controller, Get, Headers, HttpStatus, Res, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';

import { CurrentDevice, CurrentTargetsRevision, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { FlagTargetService } from 'src/modules/flag_target/flag_target.service';
import * as dtos from 'src/modules/flag_target/flag_target.dto';

// 灰度点名：用应用账号的设备密钥签名，问这个账号被点名了哪些开关。
@ApiTags('flags')
@Controller('v1/flags')
@UseGuards(DeviceAuthGuard)
export class FlagTargetController {
  constructor(private readonly targets: FlagTargetService) {}

  // 条件请求（人工决策见 src/modules/app_release/config_revision.ts）：ETag 是这台设备的点名版本（没点过名为 0），带着它来、没变回 304，不查库、不计限流。
  @Get('mine')
  async mine(
    @CurrentDevice() deviceId: string,
    @CurrentTargetsRevision() revision: string | null,
    @Headers('if-none-match') known: string | undefined,
    @Res({ passthrough: true }) response: Response,
  ): Promise<dtos.FlagTargetsDto | undefined> {
    const etag = `"${revision ?? '0'}"`;
    response.setHeader('ETag', etag);
    if (known === etag) {
      response.status(HttpStatus.NOT_MODIFIED);
      return undefined;
    }
    return this.targets.mine(deviceId);
  }
}
