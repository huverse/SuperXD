import { ApiProperty } from '@nestjs/swagger';
import { ArrayMaxSize, IsArray, IsDefined, IsInt, Matches, Max, Min } from 'class-validator';

const gamePattern = /^[a-z][a-z0-9_]{0,23}$/;

// 客户端这个版本玩得了的游戏 id（逗号分隔），服务器只给它玩得了的挑战、只从这些游戏里出题。
export class ChallengeListQueryDto {
  @ApiProperty({ description: '这个客户端玩得了的游戏 id，逗号分隔' }) @Matches(/^[a-z][a-z0-9_]{0,23}(,[a-z][a-z0-9_]{0,23}){0,63}$/) games: string;
}

export class ChallengeParamDto {
  @ApiProperty({ description: '挑战编号' }) @Matches(/^[a-z0-9_.-]{1,64}$/) challengeId: string;
}

export class ChallengeStartBodyDto {
  @ApiProperty({ description: '这个客户端玩得了的游戏 id', type: [String] }) @IsArray() @ArrayMaxSize(64) @Matches(gamePattern, { each: true }) games: string[];
}

export class ChallengeRunParamDto {
  @ApiProperty({ description: '这一局的编号' }) @Matches(/^[A-Za-z0-9_-]{22}$/) runId: string;
}

export class ChallengeLevelParamDto extends ChallengeRunParamDto {
  @ApiProperty({ description: '关卡 id' }) @Matches(/^[a-z]{1,2}$/) levelId: string;
}

// attempt 是这一关之前交过几次（从 0 起）：同一个号重发只算一次，号对不上是客户端落后了，回这一局的现状。
export class ChallengeAnswerBodyDto {
  @ApiProperty({ description: '这一关之前交过几次' }) @IsInt() @Min(0) @Max(1000) attempt: number;
  @ApiProperty({ description: '答案，按这个游戏的 Dart 规则编码' }) @IsDefined() answer: unknown;
}

export class ChallengeSummaryDto {
  @ApiProperty({ description: '挑战编号' }) id: string;
  @ApiProperty({ description: '名字，如「六连环」' }) title: string;
  @ApiProperty({ description: '档位名，如「入门」' }) label: string;
  @ApiProperty({ description: '关数' }) levels: number;
  @ApiProperty({ description: '限时，秒' }) timeLimit: number;
  @ApiProperty({ description: '开放到什么时候，毫秒' }) endsAt: number;
  @ApiProperty({ description: '这个账号在这个挑战上的最好成绩，没玩过为空', nullable: true }) best: number | null;
  @ApiProperty({ description: '这个客户端玩不了里面的游戏时为假（要更新应用）' }) playable: boolean;
}

export class ChallengeListDto {
  @ApiProperty({ description: '服务器时间，毫秒' }) serverTime: number;
  @ApiProperty({ description: '进行中的那一局，没有为空', nullable: true }) activeRun: string | null;
  @ApiProperty({ type: [ChallengeSummaryDto] }) challenges: ChallengeSummaryDto[];
}

export class ChallengeKeyedDto {
  @ApiProperty({ description: '给钥匙的关' }) from: string;
  @ApiProperty({ description: '位置（24 点第几张牌、八皇后第几行、数回第几格）' }) at: number;
  @ApiProperty({ description: '钥匙数' }) key: number;
}

export class ChallengeLevelDto {
  @ApiProperty({ description: '关卡 id' }) id: string;
  @ApiProperty({ description: '游戏 id' }) game: string;
  @ApiProperty({ description: '档位 entry、easy、normal、hard、expert' }) tier: string;
  @ApiProperty({ description: '难度分 1–10' }) difficulty: number;
  @ApiProperty({ description: '收哪几关的钥匙', type: [String] }) inputs: string[];
  @ApiProperty({ description: '钥匙给哪一关，没有为空', nullable: true }) output: string | null;
  @ApiProperty({ description: 'locked、open、solved、failed' }) state: string;
  @ApiProperty({ description: '交过几次（下一次的 attempt）' }) submissions: number;
  @ApiProperty({ description: '错交次数' }) errors: number;
  @ApiProperty({ description: '解开后给的钥匙数，没解开或不给钥匙为空', nullable: true }) key: number | null;
  @ApiProperty({ description: '锁着时的预告（收钥匙的关，挖掉的写 ?），开了为空', nullable: true }) teaser: string | null;
  @ApiProperty({ description: '题面，只在开着时给', nullable: true }) puzzle: unknown;
  @ApiProperty({ description: '题面里哪几处来自钥匙（开着时给）', type: [ChallengeKeyedDto] }) keyed: ChallengeKeyedDto[];
}

export class ChallengeResultDto {
  @ApiProperty({ description: '这一局的成绩' }) points: number;
  @ApiProperty({ description: '这一局实际加的积分（只补超过以前最好成绩的部分）' }) awarded: number;
  @ApiProperty({ description: '结束方式 cleared、stuck、timeout、ended' }) ending: string;
}

export class ChallengeRunDto {
  @ApiProperty({ description: '这一局的编号' }) runId: string;
  @ApiProperty({ description: '挑战编号' }) challengeId: string;
  @ApiProperty() title: string;
  @ApiProperty() label: string;
  @ApiProperty({ description: '限时，秒' }) timeLimit: number;
  @ApiProperty({ description: '开始时刻，毫秒' }) startedAt: number;
  @ApiProperty({ description: '到点时刻，毫秒（服务器计时，不暂停）' }) deadline: number;
  @ApiProperty({ description: '服务器时间，毫秒' }) serverTime: number;
  @ApiProperty({ description: 'running 进行中、settled 已结算' }) state: string;
  @ApiProperty({ type: [ChallengeLevelDto] }) levels: ChallengeLevelDto[];
  @ApiProperty({ type: ChallengeResultDto, nullable: true }) result: ChallengeResultDto | null;
}

export class ChallengeAnswerDto {
  @ApiProperty({ description: '这次交的对不对（重发的号回原来的结果）' }) correct: boolean;
  @ApiProperty({ description: '解开后给的钥匙数', nullable: true }) key: number | null;
  @ApiProperty({ type: ChallengeRunDto }) run: ChallengeRunDto;
}
