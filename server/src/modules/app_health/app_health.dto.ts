import { ApiProperty } from '@nestjs/swagger';
import { IsBoolean, IsIn, IsInt, IsOptional, IsString, Matches, Max, MaxLength, Min } from 'class-validator';

import { feedbackTextMax } from 'src/common/relay_limits';
import { healthFrameTiers, healthLaunchTiers } from 'src/modules/app_health/app_health_rules';

const channelPattern = /^[a-z][a-z0-9_-]{0,31}$/;

// 一份健康回报（规则见 app_health_rules.ts）：不带账号与设备号。
export class HealthReportDto {
  @ApiProperty({ description: '构建渠道，如 alpha' }) @Matches(channelPattern) channel: string;
  @ApiProperty({ description: '平台', enum: ['android', 'ios'] }) @IsIn(['android', 'ios']) platform: 'android' | 'ios';
  @ApiProperty({ description: '那天装着的版本号（构建号）' }) @IsInt() @Min(1) @Max(1 << 30) versionCode: number;
  @ApiProperty({ description: '哪一天（校园日 YYYY-MM-DD）' }) @Matches(/^\d{4}-\d{2}-\d{2}$/) day: string;
  @ApiProperty({ description: '那天有没有致命错误' }) @IsBoolean() fatal: boolean;
  @ApiProperty({ description: '启动档 0–3（Dart 入口到首帧上屏：不到 0.5 秒、0.5–1 秒、1–2 秒、2 秒以上），没有就不带', required: false }) @IsOptional() @IsInt() @Min(0) @Max(healthLaunchTiers - 1) launch?: number;
  @ApiProperty({ description: '慢帧档 0–3（慢帧占比：不到 5%、5–15%、15–40%、40% 以上），没有就不带', required: false }) @IsOptional() @IsInt() @Min(0) @Max(healthFrameTiers - 1) frames?: number;
}

// 一条新版本的意见：好或不好，可加一句话；匿名。
export class FeedbackDto {
  @ApiProperty({ description: '构建渠道，如 alpha' }) @Matches(channelPattern) channel: string;
  @ApiProperty({ description: '平台', enum: ['android', 'ios'] }) @IsIn(['android', 'ios']) platform: 'android' | 'ios';
  @ApiProperty({ description: '装着的版本号（构建号）' }) @IsInt() @Min(1) @Max(1 << 30) versionCode: number;
  @ApiProperty({ description: '好为 true，不好为 false' }) @IsBoolean() good: boolean;
  @ApiProperty({ description: '一句话，可以为空' }) @IsString() @MaxLength(feedbackTextMax) text: string;
}
