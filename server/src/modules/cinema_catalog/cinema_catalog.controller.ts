import { Body, Controller, HttpCode, HttpStatus, Ip, Param, Post } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CinemaCatalogService } from 'src/modules/cinema_catalog/cinema_catalog.service';
import * as dtos from 'src/modules/cinema_catalog/cinema_catalog.dto';

// 电影院片名目录型源的搜索（人工决策见 cinema_catalog.service.ts）：免签名、不带标识；片名放请求体里，不进地址与访问日志。
@ApiTags('app')
@Controller('v1/app/cinema/catalogs')
export class CinemaCatalogController {
  constructor(private readonly catalog: CinemaCatalogService) {}

  @Post(':id/search')
  @HttpCode(HttpStatus.OK)
  async search(@Param() param: dtos.CinemaCatalogParamDto, @Body() body: dtos.CinemaCatalogSearchBodyDto, @Ip() ip: string): Promise<dtos.CinemaCatalogSearchDto> {
    return { ids: await this.catalog.search(ip, param.id, body.q) };
  }
}
