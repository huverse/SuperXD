import { Controller, Get, Headers, Ip, Param, Query, Res } from '@nestjs/common';
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

  // 灰度配置（人工决策见客户端 lib/domain/rollout.dart）：免签名、不带任何标识，客户端在本机判定。
  // 两份配置都认条件请求（人工决策见 config_revision.ts）：ETag 是公共配置的版本号，没变回 304。
  @Get('rollout')
  rollout(@Ip() ip: string, @Headers('if-none-match') known: string | undefined, @Res({ passthrough: true }) response: Response): Promise<dtos.RolloutConfigDto | undefined> {
    return this.releases.rollout(ip, known, response);
  }

  // 第 2 版灰度配置（开关带条件、参数与时间窗，人工决策见客户端 lib/domain/rollout.dart 的 11-16 那条）：只有签名信封，同样免签名、不带标识。
  @Get('flags')
  flags(@Ip() ip: string, @Headers('if-none-match') known: string | undefined, @Res({ passthrough: true }) response: Response): Promise<dtos.FlagConfigResponseDto | undefined> {
    return this.releases.flags(ip, known, response);
  }

  // 电影院的片源规则包（人工决策见客户端 lib/toolbox/cinema/cinema_service.dart 文件头）：只有签名信封，免签名、不带标识。
  @Get('cinema')
  cinema(@Ip() ip: string): Promise<dtos.CinemaRulesDto> {
    return this.releases.cinema(ip);
  }

  @Get('files/:name')
  file(@Param() param: dtos.AppFileParamDto, @Ip() ip: string, @Res() response: Response): Promise<void> {
    return this.releases.send(ip, param.name, response);
  }
}
