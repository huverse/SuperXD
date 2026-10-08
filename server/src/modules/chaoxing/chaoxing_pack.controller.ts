import { Body, Controller, HttpCode, Ip, Param, Post } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { ChaoxingPackService } from 'src/modules/chaoxing/chaoxing_pack.service';
import * as dtos from 'src/modules/chaoxing/chaoxing_pack.dto';

// 代签凭据包的临时中转，不做设备签名（见 service 里的人工决策说明）。
@ApiTags('chaoxing')
@Controller('v1/chaoxing/packs')
export class ChaoxingPackController {
  constructor(private readonly packs: ChaoxingPackService) {}

  @Post()
  @HttpCode(200)
  submit(@Body() body: dtos.SubmitChaoxingPackDto, @Ip() ip: string): Promise<dtos.SubmitChaoxingPackResultDto> {
    return this.packs.submit(ip, body.data);
  }

  // 出示方换码时作废上一张；无论包在不在都回 204，不透露是否存在。
  @Post(':id/revoke')
  @HttpCode(204)
  revoke(@Param() param: dtos.PickupChaoxingPackParamDto, @Body() body: dtos.RevokeChaoxingPackDto, @Ip() ip: string): Promise<void> {
    return this.packs.revoke(ip, param.id, body.token);
  }

  @Post(':id/pickup')
  @HttpCode(200)
  pickup(@Param() param: dtos.PickupChaoxingPackParamDto, @Ip() ip: string): Promise<dtos.PickupChaoxingPackResultDto> {
    return this.packs.pickup(ip, param.id);
  }
}
