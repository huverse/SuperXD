import { ApiProperty } from '@nestjs/swagger';
import { IsInt, Matches, Max, Min } from 'class-validator';

import { rewardActiveWindow } from 'src/modules/reward/reward_odds';

export const rewardPrizeKinds = ['password', 'qrcode'] as const;
export type RewardPrizeKind = (typeof rewardPrizeKinds)[number];

export class RewardDrawParamDto {
  @ApiProperty({ description: '活动编号，同客户端的节日编号，如 spring-2027' }) @Matches(/^[a-z0-9][a-z0-9-]{0,63}$/) campaign: string;
}

export class RewardDrawBodyDto {
  @ApiProperty({ description: '参与号：客户端第一次参与时本机生成的 16 字节随机数（base64url），不关联任何账号；服务端只存 sha256' }) @Matches(/^[A-Za-z0-9_-]{22}$/) participant: string;
  @ApiProperty({ description: '近 30 天里打开过应用的天数（客户端本机记）' }) @IsInt() @Min(0) @Max(rewardActiveWindow) activeDays: number;
}

export class RewardPrizeDto {
  @ApiProperty({ description: 'password 支付宝口令，qrcode 二维码内容', enum: rewardPrizeKinds }) kind: RewardPrizeKind;
  @ApiProperty({ description: '口令原文或二维码内容' }) content: string;
  @ApiProperty({ description: '附言，可为空' }) note: string;
}

export class RewardDrawDto {
  @ApiProperty({ description: 'won 抽中，missed 没抽中，closed 活动不存在或不在进行中', enum: ['won', 'missed', 'closed'] }) result: 'won' | 'missed' | 'closed';
  @ApiProperty({ description: '抽中时的奖品', type: RewardPrizeDto, nullable: true }) prize: RewardPrizeDto | null;
}
