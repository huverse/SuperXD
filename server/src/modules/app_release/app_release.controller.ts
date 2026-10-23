import { Controller, Get, Ip, Param, Query, Res } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';

import { AppReleaseService } from 'src/modules/app_release/app_release.service';
import * as dtos from 'src/modules/app_release/app_release.dto';

// 应用内检查更新与下载安装包，免签名（客户端未开私信也要能更新）。
@ApiTags('app')
@Controller('v1/app')
export class AppReleaseController {
  constructor(private readonly releases: AppReleaseService) {}

  @Get('releases/:channel')
  latest(@Param() param: dtos.AppReleaseParamDto, @Query() query: dtos.AppReleaseQueryDto, @Ip() ip: string): Promise<dtos.AppReleaseDto> {
    return this.releases.latest(ip, param.channel, query.abi);
  }

  // 开发者的话：免签名、不带任何标识。
  @Get('notes')
  notes(@Ip() ip: string): Promise<dtos.DeveloperNotesDto> {
    return this.releases.notes(ip);
  }

  @Get('files/:name')
  file(@Param() param: dtos.AppFileParamDto, @Ip() ip: string, @Res() response: Response): Promise<void> {
    return this.releases.send(ip, param.name, response);
  }
}
