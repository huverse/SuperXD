import { ApiProperty } from '@nestjs/swagger';
import { IsBoolean, IsIn, IsInt, IsOptional, Matches, Max, Min } from 'class-validator';

import { rewardActiveWindow } from 'src/modules/reward/reward_odds';

export class RewardDrawParamDto {
  @ApiProperty({ description: '活动编号，同客户端的节日编号，如 spring-2027' }) @Matches(/^[a-z0-9][a-z0-9-]{0,63}$/) campaign: string;
}

// 抽签人是签名的设备（x-sxd-device），请求体里不再带参与号。
export class RewardDrawBodyDto {
  @ApiProperty({ description: '近 30 天里打开过应用的天数（客户端本机记）' }) @IsInt() @Min(0) @Max(rewardActiveWindow) activeDays: number;
  @ApiProperty({ description: '为 false 时不按积分等级加权（客户端联网偏好是仅本机），缺省按等级', required: false }) @IsOptional() @IsBoolean() levels?: boolean;
  // 11-17 起的客户端带 2：奖品给带服务器签名的第 2 版信封（见 reward_seal.ts）；没带的旧客户端给第 1 版。
  @ApiProperty({ description: '要哪一版奖品信封：2 带服务器签名；缺省第 1 版（旧客户端）', required: false, enum: [2] }) @IsOptional() @IsIn([2]) seal?: 2;
}

export class RewardDrawDto {
  @ApiProperty({ description: 'won 抽中，missed 没抽中，closed 活动不存在或不在进行中，ineligible 没资格（不在名单或等级不够，不记这次），sold_out 发完为止的活动这一批领完了（不记这次，补货后还能领）', enum: ['won', 'missed', 'closed', 'ineligible', 'sold_out'] })
  result: 'won' | 'missed' | 'closed' | 'ineligible' | 'sold_out';
  @ApiProperty({ description: '抽中时的奖品 {kind（password 支付宝口令、qrcode 二维码内容）, content, note}，用抽签设备的 box 公钥封装、请求带 seal: 2 时另接服务器签名（见 reward_seal.ts），base64url', nullable: true }) sealed: string | null;
}

// 查状态的查询参数：levels=0 时不按积分等级（客户端联网偏好是仅本机），同抽签请求体的 levels。
export class RewardStatusQueryDto {
  @ApiProperty({ description: '0 不按积分等级，缺省按等级', required: false }) @IsOptional() @IsIn(['0', '1']) levels?: '0' | '1';
}

// 查一个活动能不能领（信里的「领取」按钮先问；人工决策见 reward_odds.ts 的 11-16 那条）。
export class RewardStatusDto {
  @ApiProperty({ description: 'open 能领，drawn 领过，closed 不在进行，ineligible 没资格，too_new 账号天数不够，sold_out 发完为止的活动这一批领完了', enum: ['open', 'drawn', 'closed', 'ineligible', 'too_new', 'sold_out'] })
  state: 'open' | 'drawn' | 'closed' | 'ineligible' | 'too_new' | 'sold_out';
  @ApiProperty({ description: '活动结束时刻（ISO 8601，UTC）；活动不存在为空', type: String, nullable: true }) endsAt: string | null;
  @ApiProperty({ description: 'too_new 时可以领的时刻，毫秒', type: Number, nullable: true }) eligibleAt: number | null;
}
