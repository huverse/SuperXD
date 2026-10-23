import { ApiProperty } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { ArrayMaxSize, IsArray, IsIn, IsInt, IsISO8601, IsString, Matches, MaxLength, Min, MinLength, ValidateNested } from 'class-validator';

import { developerNoteBodyMax, developerNoteLimit, developerNoteTitleMax } from 'src/common/relay_limits';

// 客户端按自己正在运行的 CPU 架构取安装包，与发布附件的三种分包一致。
export const appAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'] as const;

// 安装包文件名：只许字母数字与 . _ -，以 .apk 结尾，杜绝路径穿越。
const apkFileName = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.apk$/;

export class AppReleaseParamDto {
  @ApiProperty({ description: '发布渠道，与应用的构建渠道一致，如 alpha' }) @Matches(/^[a-z][a-z0-9_-]{0,31}$/) channel: string;
}

export class AppReleaseQueryDto {
  @ApiProperty({ description: '客户端 CPU 架构', enum: appAbis }) @IsIn(appAbis) abi: (typeof appAbis)[number];
}

export class AppFileParamDto {
  @ApiProperty({ description: '安装包文件名' }) @Matches(apkFileName) name: string;
}

export class AppReleaseApkDto {
  @ApiProperty({ description: '下载路径，相对中转地址' }) url: string;
  @ApiProperty({ description: '字节数' }) size: number;
  @ApiProperty({ description: 'SHA-256，小写十六进制' }) sha256: string;
}

export class AppReleaseDto {
  @ApiProperty({ description: '版本号（整数，比较新旧用它）' }) versionCode: number;
  @ApiProperty({ description: '版本名，展示用' }) versionName: string;
  @ApiProperty({ description: '发布时刻，ISO 8601 带时区' }) publishedAt: string;
  @ApiProperty({ description: '最低可用版本号：已装版本低于它时必须更新' }) minSupportedVersionCode: number;
  @ApiProperty({ description: '更新说明' }) notes: string;
  @ApiProperty({ description: '发布页，下载失败时用浏览器打开' }) releasePage: string;
  @ApiProperty({ description: '这个架构的安装包；没有时为空，客户端改用发布页', type: AppReleaseApkDto, nullable: true }) apk: AppReleaseApkDto | null;
}

// 以下是发版时放进目录的清单文件（<渠道>.json）的格式，读入时逐项校验，放错或写坏了不往外发。
export class AppReleaseFileApk {
  @IsIn(appAbis) abi: (typeof appAbis)[number];
  @Matches(apkFileName) file: string;
  @IsInt() @Min(1) size: number;
  @Matches(/^[0-9a-f]{64}$/) sha256: string;
}

export class AppReleaseFile {
  @IsInt() @Min(1) versionCode: number;
  @IsString() @MaxLength(64) versionName: string;
  @IsISO8601({ strict: true }) publishedAt: string;
  @IsInt() @Min(0) minSupportedVersionCode: number;
  @IsString() @MaxLength(4000) notes: string;
  @Matches(/^https:\/\/\S{1,500}$/) releasePage: string;
  @ValidateNested({ each: true }) @Type(() => AppReleaseFileApk) @ArrayMaxSize(appAbis.length) apks: AppReleaseFileApk[];
}

// 开发者的话：流水线由仓库 notes 目录生成的 developer_notes.json（tool/developer_notes.dart），读入时逐项校验，写坏了不往外发。
export class DeveloperNoteDto {
  @ApiProperty({ description: '编号，即仓库 notes 目录里的文件名，发出后不改' }) @Matches(/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/) id: string;
  @ApiProperty({ description: '标题' }) @IsString() @MinLength(1) @MaxLength(developerNoteTitleMax) title: string;
  @ApiProperty({ description: '发出时刻，ISO 8601 带时区' }) @IsISO8601({ strict: true }) publishedAt: string;
  @ApiProperty({ description: '正文，原样显示' }) @IsString() @MinLength(1) @MaxLength(developerNoteBodyMax) body: string;
}

export class DeveloperNotesDto {
  @ApiProperty({ description: '最近的信，从新到旧', type: [DeveloperNoteDto] }) @IsArray() @ValidateNested({ each: true }) @Type(() => DeveloperNoteDto) @ArrayMaxSize(developerNoteLimit) notes: DeveloperNoteDto[];
}
