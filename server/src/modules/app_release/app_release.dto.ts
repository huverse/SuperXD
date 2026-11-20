import { ApiProperty } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { ArrayMaxSize, ArrayMinSize, IsArray, IsIn, IsInt, IsISO8601, IsOptional, IsString, Matches, Max, MaxLength, Min, MinLength, ValidateNested } from 'class-validator';

import { developerNoteAttachmentMax, developerNoteBodyMax, developerNoteLimit, developerNoteTitleMax, pointsLevelCount, rolloutFlagLimit, rolloutStageLimit, unlockLimit, unlockPriceMax, unlockTitleMax } from 'src/common/relay_limits';

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

// 信的附件（11-16 起，人工决策见 src/modules/reward/reward_odds.ts 的 11-16 那条）：类型加指向的对象，客户端按类型找渲染、不认识的不显示；
// 现在只有 reward（ref 是红包活动编号）。旧版本客户端不认这个字段，照常显示信。
export class DeveloperNoteAttachmentDto {
  @ApiProperty({ description: '附件类型，如 reward' }) @Matches(/^[a-z][a-z0-9_-]{0,15}$/) type: string;
  @ApiProperty({ description: '附件指向的对象，reward 是活动编号' }) @Matches(/^[a-z0-9][a-z0-9-]{0,63}$/) ref: string;
}

// 开发者的话：流水线由仓库 notes 目录生成的 developer_notes.json（tool/developer_notes.dart），读入时逐项校验，写坏了不往外发。
export class DeveloperNoteDto {
  @ApiProperty({ description: '编号，即仓库 notes 目录里的文件名，发出后不改' }) @Matches(/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/) id: string;
  @ApiProperty({ description: '标题' }) @IsString() @MinLength(1) @MaxLength(developerNoteTitleMax) title: string;
  @ApiProperty({ description: '发出时刻，ISO 8601 带时区' }) @IsISO8601({ strict: true }) publishedAt: string;
  @ApiProperty({ description: '正文，原样显示' }) @IsString() @MinLength(1) @MaxLength(developerNoteBodyMax) body: string;
  @ApiProperty({ description: '附件，可以没有', type: [DeveloperNoteAttachmentDto], required: false })
  @IsOptional()
  @IsArray()
  @ArrayMaxSize(developerNoteAttachmentMax)
  @ValidateNested({ each: true })
  @Type(() => DeveloperNoteAttachmentDto)
  attachments?: DeveloperNoteAttachmentDto[];
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

// 灰度配置（人工决策见客户端 lib/domain/rollout.dart）：维护者本机签好的第 1 版 rollout.json（tool/rollout_config.dart，只放没有新字段的开关），
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

// 一项解锁（规则见 src/modules/unlock/unlock_rules.ts）：id 用约定前缀（game.<游戏 id>、toolbox.<工具 id>），title 是积分页上的名字；
// 等级门槛、价格、抽签比例、公开时刻至少写一个（下架的除外），满足任一就开；retired 只写 true。
export class RolloutUnlockDto {
  @ApiProperty({ description: '解锁的编号，如 game.sudoku' }) @Matches(/^[a-z0-9][a-z0-9._-]{0,63}$/) id: string;
  @ApiProperty({ description: '积分页上的名字' }) @IsString() @MinLength(1) @MaxLength(unlockTitleMax) title: string;
  @ApiProperty({ description: '等级到这么多就开（1–5）', required: false }) @IsOptional() @IsInt() @Min(1) @Max(pointsLevelCount - 1) minLevel?: number;
  @ApiProperty({ description: '花这么多积分永久解锁', required: false }) @IsOptional() @IsInt() @Min(1) @Max(unlockPriceMax) price?: number;
  @ApiProperty({ description: '按积分等级加权抽签的比例（1–100）', required: false }) @IsOptional() @IsInt() @Min(1) @Max(100) percent?: number;
  @ApiProperty({ description: '从这一刻起人人可用，ISO 8601 带时区', required: false }) @IsOptional() @IsISO8601({ strict: true }) @Matches(/(Z|[+-]\d\d:\d\d)$/) publicAt?: string;
  @ApiProperty({ description: '下架：谁都不能用，买过的退回积分', required: false }) @IsOptional() @IsIn([true]) retired?: true;
}

// 第 2 版灰度配置（人工决策见客户端 lib/domain/rollout.dart 的 11-16 那条）：只有签名信封，载荷（开关的条件、参数与时间窗、等级门槛、解锁清单）
// 只由客户端验签后解码，服务端不再重复一遍规则；还没放文件时信封为空，客户端退回第 1 版的 /v1/app/rollout。
export class FlagConfigDto {
  @ApiProperty({ description: '配置写法版本，固定 2' }) @IsIn([2]) version: 2;
  @ApiProperty({ description: '签名信封（载荷是第 2 版配置的 UTF-8 JSON）', type: SignedEnvelopeDto, nullable: true })
  @IsOptional()
  @ValidateNested()
  @Type(() => SignedEnvelopeDto)
  envelope: SignedEnvelopeDto | null;
}

// /v1/app/flags 的回复：文件里的签名信封，另带健康回报自动暂停的分批更新（不签名，人工决策见 src/modules/app_health/app_health_rules.ts；客户端只拿它少提示）。
export class FlagConfigResponseDto extends FlagConfigDto {
  @ApiProperty({ description: '自动暂停的分批更新开关名（app_update.<渠道>.<版本号>），不签名', type: [String] }) paused: string[];
}

// 电影院的片源规则包（人工决策见客户端 lib/toolbox/cinema/cinema_service.dart 文件头）：只有签名信封，载荷（片源规则与云解析）只由客户端验签后解码；
// 还没放文件时信封为空，客户端照旧用本机缓存的。
export class CinemaRulesDto {
  @ApiProperty({ description: '文件写法版本，固定 1' }) @IsIn([1]) version: 1;
  @ApiProperty({ description: '签名信封（载荷是规则包的 UTF-8 JSON）', type: SignedEnvelopeDto, nullable: true })
  @IsOptional()
  @ValidateNested()
  @Type(() => SignedEnvelopeDto)
  envelope: SignedEnvelopeDto | null;
}

export class RolloutConfigDto {
  @ApiProperty({ description: '全部开关', type: [RolloutFlagDto] }) @IsArray() @ValidateNested({ each: true }) @Type(() => RolloutFlagDto) @ArrayMaxSize(rolloutFlagLimit) flags: RolloutFlagDto[];
  // 积分等级 Lv0–Lv5 的门槛（近 12 个月获得的积分，规则见 src/modules/points/points_level.ts），从 0 起严格递增，由 RolloutSource 再核一遍。
  @ApiProperty({ description: '积分等级的门槛，六个数', type: [Number], required: false })
  @IsOptional()
  @IsArray()
  @ArrayMinSize(pointsLevelCount)
  @ArrayMaxSize(pointsLevelCount)
  @IsInt({ each: true })
  @Min(0, { each: true })
  @Max(100_000_000, { each: true })
  levels?: number[];
  @ApiProperty({ description: '解锁（隐藏服务与新游戏抢先玩）', type: [RolloutUnlockDto], required: false })
  @IsOptional()
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => RolloutUnlockDto)
  @ArrayMaxSize(unlockLimit)
  unlocks?: RolloutUnlockDto[];
  @ApiProperty({ description: '签好的信封，客户端只认它；还没放文件时为空', type: SignedEnvelopeDto, nullable: true })
  @IsOptional()
  @ValidateNested()
  @Type(() => SignedEnvelopeDto)
  envelope?: SignedEnvelopeDto | null;
}
