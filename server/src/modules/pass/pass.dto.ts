import { ApiProperty } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { ArrayMaxSize, IsArray, IsInt, IsString, Matches, Max, MaxLength, Min, MinLength, ValidateNested } from 'class-validator';

import { passDaysMax, passOfferLimit, passPriceMax } from 'src/common/relay_limits';

export class PassParamDto {
  @ApiProperty({ description: '券的编号，如 toolbox.cinema' }) @Matches(/^[a-z0-9][a-z0-9._-]{0,63}$/) id: string;
}

// 发布目录 passes.json 的一种券：多少积分换几天。
export class PassOfferDto {
  @ApiProperty({ description: '券的编号，同要收费的服务，如 toolbox.cinema' }) @Matches(/^[a-z0-9][a-z0-9._-]{0,63}$/) id: string;
  @ApiProperty({ description: '给用户看的名字' }) @IsString() @MinLength(1) @MaxLength(20) title: string;
  @ApiProperty({ description: '每次花多少积分' }) @IsInt() @Min(1) @Max(passPriceMax) price: number;
  @ApiProperty({ description: '每次换几天' }) @IsInt() @Min(1) @Max(passDaysMax) days: number;
}

export class PassOffersDto {
  @ApiProperty({ description: '现在要用积分换时长的服务', type: [PassOfferDto] }) @IsArray() @ArrayMaxSize(passOfferLimit) @ValidateNested({ each: true }) @Type(() => PassOfferDto) offers: PassOfferDto[];
}

export class PassHeldDto {
  @ApiProperty({ description: '券的编号' }) id: string;
  @ApiProperty({ description: '到期时刻，毫秒' }) until: number;
}

export class PassStateDto {
  @ApiProperty({ description: '这个账号还没到期的券', type: [PassHeldDto] }) held: PassHeldDto[];
  @ApiProperty({ description: '服务器时间，毫秒' }) serverTime: number;
}
