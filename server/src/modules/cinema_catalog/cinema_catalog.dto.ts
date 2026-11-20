import { ApiProperty } from '@nestjs/swagger';
import { IsString, Length, Matches } from 'class-validator';

import { cinemaCatalogKeywordMax } from 'src/common/relay_limits';

export class CinemaCatalogParamDto {
  @ApiProperty({ description: '片源规则包 catalogRules 里的规则编号' }) @Matches(/^[a-z0-9][a-z0-9_-]{0,31}$/) id: string;
}

export class CinemaCatalogSearchBodyDto {
  @ApiProperty({ description: '片名（不落库、不写日志）' }) @IsString() @Length(1, cinemaCatalogKeywordMax) q: string;
}

export class CinemaCatalogSearchDto {
  @ApiProperty({ description: '这个源里的影片编号，最多 cinemaCatalogHits 个', type: [String] }) ids: string[];
}
