import { ApiProperty } from '@nestjs/swagger';
import { IsBoolean, IsInt, IsOptional, Matches, Max, Min } from 'class-validator';

import { rewardActiveWindow } from 'src/modules/reward/reward_odds';

export class RewardDrawParamDto {
  @ApiProperty({ description: '活动编号，同客户端的节日编号，如 spring-2027' }) @Matches(/^[a-z0-9][a-z0-9-]{0,63}$/) campaign: string;
}

// 抽签人是签名的设备（x-sxd-device），请求体里不再带参与号。
export class RewardDrawBodyDto {
  @ApiProperty({ description: '近 30 天里打开过应用的天数（客户端本机记）' }) @IsInt() @Min(0) @Max(rewardActiveWindow) activeDays: number;
  @ApiProperty({ description: '为 false 时不按积分等级加权（客户端关掉了娱乐与积分），缺省按等级', required: false }) @IsOptional() @IsBoolean() levels?: boolean;
}

export class RewardDrawDto {
  @ApiProperty({ description: 'won 抽中，missed 没抽中，closed 活动不存在或不在进行中', enum: ['won', 'missed', 'closed'] }) result: 'won' | 'missed' | 'closed';
  @ApiProperty({ description: '抽中时的奖品 {kind（password 支付宝口令、qrcode 二维码内容）, content, note}，用抽签设备的 box 公钥封装（见 reward_seal.ts），base64url', nullable: true }) sealed: string | null;
}
