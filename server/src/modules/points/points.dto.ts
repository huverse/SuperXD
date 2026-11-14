import { ApiProperty } from '@nestjs/swagger';
import { IsOptional, Matches } from 'class-validator';

export class PointsSummaryDto {
  @ApiProperty({ description: '余额（没过期的积分）' }) balance: number;
  @ApiProperty({ description: '30 天内要过期的合计' }) expiring: number;
  @ApiProperty({ description: '其中最早的过期时刻，毫秒；没有为空', nullable: true }) expiringAt: number | null;
  @ApiProperty({ description: '近 12 个月获得的总数（没过期的获得，花了不减），等级按它算' }) earned: number;
  @ApiProperty({ description: '等级 0–5（Lv0–Lv5）' }) level: number;
  @ApiProperty({ description: '到下一级要的获得总数；已是最高级或还没配门槛为空', nullable: true }) nextLevelAt: number | null;
  @ApiProperty({ description: '服务器时间，毫秒' }) serverTime: number;
}

export class PointsEntriesQueryDto {
  @ApiProperty({ description: '上一页最后一条的编号，第一页不传', required: false }) @IsOptional() @Matches(/^[1-9]\d{0,19}$/) before?: string;
}

export class PointsEntryDto {
  @ApiProperty({ description: '编号，翻页用' }) id: string;
  @ApiProperty({ description: 'earn 获得、expire 过期、spend 花费、refund 退回' }) kind: string;
  @ApiProperty({ description: '正数加、负数减' }) amount: number;
  @ApiProperty({ description: '给用户看的说明，如挑战名' }) note: string;
  @ApiProperty({ description: '时刻，毫秒' }) at: number;
}

export class PointsEntriesDto {
  @ApiProperty({ type: [PointsEntryDto], description: '从新到旧' }) entries: PointsEntryDto[];
  @ApiProperty({ description: '下一页的 before，没有更多为空', nullable: true }) next: string | null;
}
