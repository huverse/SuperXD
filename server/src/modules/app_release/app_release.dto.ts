import { ApiProperty } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { ArrayMaxSize, ArrayMinSize, IsArray, IsIn, IsInt, IsISO8601, IsOptional, IsString, Matches, Max, MaxLength, Min, MinLength, ValidateNested } from 'class-validator';

import { developerNoteBodyMax, developerNoteLimit, developerNoteTitleMax, rolloutFlagLimit, rolloutStageLimit } from 'src/common/relay_limits';

// 客户端按自己正在运行的 CPU 架构取安装包，与发布附件的三种分包一致。
export const appAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'] as const;

// 签名信封（人工决策见客户端 lib/device/signed_content.dart）：发版与 notes 流水线签好放进文件，这里只校验形状、原样透传，
// 不解码、不验签（受信公钥只内置在客户端）。一个信封最多 4 个签名，与客户端 signedEnvelopeSignatureMax 一致。
export class ContentSignatureDto {
  @ApiProperty({ description: '签名钥编号，客户端按它找内置的受信公钥' }) @Matches(/^[a-z0-9][a-z0-9._-]{0,31}$/) keyId: string;
  @ApiProperty({ description: 'Ed25519 签名 64 字节的 base64url' }) @Matches(/^[A-Za-z0-9_-]{86}$/) sig: string;
}

export class SignedEnvelopeDto {
  @ApiProperty({ description: '载荷 UTF-8 JSON 字节的 base64url' }) @Matches(/^[A-Za-z0-9_-]+$/) signed: string;
  @ApiProperty({ description: '签名，任一受信公钥验过即可', type: [ContentSignatureDto] })
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(4)
  @ValidateNested({ each: true })
  @Type(() => ContentSignatureDto)
  signatures: ContentSignatureDto[];
}

// 安装包文件名：只许字母数字与 . _ -，以 .apk 结尾，杜绝路径穿越。
const apkFileName = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.apk$/;

export class AppReleaseParamDto {
  @ApiProperty({ description: '发布渠道，与应用的构建渠道一致，如 alpha' }) @Matches(/^[a-z][a-z0-9_-]{0,31}$/) channel: string;
}

export class AppReleaseQueryDto {
  @ApiProperty({ description: '客户端 CPU 架构', enum: appAbis }) @IsIn(appAbis) abi: (typeof appAbis)[number];
}

// 下载接口的文件名：安装包，或按需下载的字体包文件（.ttf，客户端核对写死的 SHA-256，见客户端 lib/domain/font_pack.dart）。
// 只许字母数字与 . _ -、不以点开头，杜绝路径穿越与清单等别的文件。
const appDownloadFileName = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(apk|ttf)$/;

export class AppFileParamDto {
  @ApiProperty({ description: '安装包或字体包文件名' }) @Matches(appDownloadFileName) name: string;
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
  @ApiProperty({ description: '这个架构签好的信封，新客户端只认它（以上明文字段留给不验签的旧客户端）；清单里没有时为空', type: SignedEnvelopeDto, nullable: true })
  envelope: SignedEnvelopeDto | null;
}

// 以下是发版时放进目录的清单文件（<渠道>.json）的格式，读入时逐项校验，放错或写坏了不往外发。
export class AppReleaseFileApk {
  @IsIn(appAbis) abi: (typeof appAbis)[number];
  @Matches(apkFileName) file: string;
  @IsInt() @Min(1) size: number;
  @Matches(/^[0-9a-f]{64}$/) sha256: string;
}

export class AppReleaseFileEnvelopes {
  @IsOptional() @ValidateNested() @Type(() => SignedEnvelopeDto) 'arm64-v8a'?: SignedEnvelopeDto;
  @IsOptional() @ValidateNested() @Type(() => SignedEnvelopeDto) 'armeabi-v7a'?: SignedEnvelopeDto;
  @IsOptional() @ValidateNested() @Type(() => SignedEnvelopeDto) x86_64?: SignedEnvelopeDto;
}

export class AppReleaseFile {
  @IsInt() @Min(1) versionCode: number;
  @IsString() @MaxLength(64) versionName: string;
  @IsISO8601({ strict: true }) publishedAt: string;
  @IsInt() @Min(0) minSupportedVersionCode: number;
  @IsString() @MaxLength(4000) notes: string;
  @Matches(/^https:\/\/\S{1,500}$/) releasePage: string;
  @ValidateNested({ each: true }) @Type(() => AppReleaseFileApk) @ArrayMaxSize(appAbis.length) apks: AppReleaseFileApk[];
  // 每个架构各签一份（tool/release_manifest.dart）；1.0.0-alpha.15 及以前发版写的清单没有这一项。
  @IsOptional() @ValidateNested() @Type(() => AppReleaseFileEnvelopes) envelopes?: AppReleaseFileEnvelopes;
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
  // 签好的同一批信（tool/developer_notes.dart），新客户端只认它；还没放文件或文件里没有时返回空。
  @ApiProperty({ description: '签好的信封，新客户端只认它（notes 留给不验签的旧客户端）；没有时为空', type: SignedEnvelopeDto, nullable: true })
  @IsOptional()
  @ValidateNested()
  @Type(() => SignedEnvelopeDto)
  envelope?: SignedEnvelopeDto | null;
}

// 灰度配置（人工决策见客户端 lib/domain/rollout.dart）：流水线由仓库 rollout/rollout.json 生成的 rollout.json（tool/rollout_config.dart），
// 这里只校验形状（开关名、定值或放量表），按时间先后、只增不减这些语义由客户端校验；写坏了不往外发。
export class RolloutStageDto {
  @ApiProperty({ description: '这一档从什么时刻起，ISO 8601 带时区' }) @IsISO8601({ strict: true }) from: string;
  @ApiProperty({ description: '放量百分比 0–100' }) @IsInt() @Min(0) @Max(100) percent: number;
}

export class RolloutFlagDto {
  @ApiProperty({ description: '开关名，分批更新是 app_update.<渠道>.<版本号>' }) @Matches(/^[a-z0-9][a-z0-9._-]{0,63}$/) id: string;
  @ApiProperty({ description: '定值放量百分比（与 stages 二选一）', required: false }) @IsOptional() @IsInt() @Min(0) @Max(100) percent?: number;
  @ApiProperty({ description: '按时刻的放量表（与 percent 二选一）', type: [RolloutStageDto], required: false })
  @IsOptional()
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(rolloutStageLimit)
  @ValidateNested({ each: true })
  @Type(() => RolloutStageDto)
  stages?: RolloutStageDto[];
}

export class RolloutConfigDto {
  @ApiProperty({ description: '全部开关', type: [RolloutFlagDto] }) @IsArray() @ValidateNested({ each: true }) @Type(() => RolloutFlagDto) @ArrayMaxSize(rolloutFlagLimit) flags: RolloutFlagDto[];
  @ApiProperty({ description: '签好的信封，客户端只认它；还没放文件时为空', type: SignedEnvelopeDto, nullable: true })
  @IsOptional()
  @ValidateNested()
  @Type(() => SignedEnvelopeDto)
  envelope?: SignedEnvelopeDto | null;
}
