import { ApiProperty } from '@nestjs/swagger';
import { IsBoolean, IsIn, IsInt, IsString, Matches, Max, MaxLength, Min } from 'class-validator';

import { feedbackTextMax } from 'src/common/relay_limits';

const channelPattern = /^[a-z][a-z0-9_-]{0,31}$/;

// 一份健康回报（规则见 app_health_rules.ts）：不带账号与设备号。
export class HealthReportDto {
  @ApiProperty({ description: '构建渠道，如 alpha' }) @Matches(channelPattern) channel: string;
  @ApiProperty({ description: '平台', enum: ['android', 'ios'] }) @IsIn(['android', 'ios']) platform: 'android' | 'ios';
  @ApiProperty({ description: '那天装着的版本号（构建号）' }) @IsInt() @Min(1) @Max(1 << 30) versionCode: number;
  @ApiProperty({ description: '哪一天（校园日 YYYY-MM-DD）' }) @Matches(/^\d{4}-\d{2}-\d{2}$/) day: string;
  @ApiProperty({ description: '那天有没有致命错误' }) @IsBoolean() fatal: boolean;
}

// 一条新版本的意见：好或不好，可加一句话；匿名。
export class FeedbackDto {
  @ApiProperty({ description: '构建渠道，如 alpha' }) @Matches(channelPattern) channel: string;
  @ApiProperty({ description: '平台', enum: ['android', 'ios'] }) @IsIn(['android', 'ios']) platform: 'android' | 'ios';
  @ApiProperty({ description: '装着的版本号（构建号）' }) @IsInt() @Min(1) @Max(1 << 30) versionCode: number;
  @ApiProperty({ description: '好为 true，不好为 false' }) @IsBoolean() good: boolean;
  @ApiProperty({ description: '一句话，可以为空' }) @IsString() @MaxLength(feedbackTextMax) text: string;
}
