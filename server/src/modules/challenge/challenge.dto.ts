import { ApiProperty } from '@nestjs/swagger';
import { ArrayMaxSize, IsArray, IsDefined, IsInt, Matches, Max, Min } from 'class-validator';

// 一个玩得了的游戏：「游戏 id@题面写法版本」（hanoi@1）；只写游戏 id 的是 11-15 以前的客户端，按第 1 版（人工决策见客户端 challenge_rules.dart 的 11-15 19:18 那条）。
const gamePattern = /^[a-z][a-z0-9_]{0,23}(@[1-9][0-9]{0,3})?$/;

// 客户端这个版本玩得了的游戏（逗号分隔），服务器只给它玩得了的挑战、只从这些游戏与题面写法版本里出题。
export class ChallengeListQueryDto {
  @ApiProperty({ description: '这个客户端玩得了的游戏，「游戏 id@题面写法版本」逗号分隔（只写 id 按第 1 版）' })
  @Matches(/^[a-z][a-z0-9_]{0,23}(@[1-9][0-9]{0,3})?(,[a-z][a-z0-9_]{0,23}(@[1-9][0-9]{0,3})?){0,63}$/)
  games: string;
}

export class ChallengeParamDto {
  @ApiProperty({ description: '挑战编号' }) @Matches(/^[a-z0-9_.-]{1,64}$/) challengeId: string;
}

export class ChallengeStartBodyDto {
  @ApiProperty({ description: '这个客户端玩得了的游戏，「游戏 id@题面写法版本」（只写 id 按第 1 版）', type: [String] }) @IsArray() @ArrayMaxSize(64) @Matches(gamePattern, { each: true }) games: string[];
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
  @ApiProperty({ description: '每一关的档位（模板里的顺序），首页画结构缩略图用', type: [String] }) tiers: string[];
  @ApiProperty({ description: '边：给碎片的关与收碎片的关在 tiers 里的下标', type: 'array', items: { type: 'array', items: { type: 'integer' } } }) edges: number[][];
  @ApiProperty({ description: '限时，秒' }) timeLimit: number;
  @ApiProperty({ description: '开放到什么时候，毫秒' }) endsAt: number;
  @ApiProperty({ description: '这个账号在这个挑战上的最好成绩，没玩过为空', nullable: true }) best: number | null;
  @ApiProperty({ description: '这个客户端玩不了里面的游戏时为假（要更新应用）' }) playable: boolean;
  @ApiProperty({ description: '开局要付的积分门票，0 是免费；开局即扣，过没过都不退' }) ticket: number;
}

export class ChallengeListDto {
  @ApiProperty({ description: '服务器时间，毫秒' }) serverTime: number;
  @ApiProperty({ description: '进行中的那一局，没有为空', nullable: true }) activeRun: string | null;
  @ApiProperty({ type: [ChallengeSummaryDto] }) challenges: ChallengeSummaryDto[];
}

// 门：门上的数 = inputs 几关碎片的和（sum）或积（product），只有一关就是那个碎片；开了才给门上的数。
export class ChallengeGateDto {
  @ApiProperty({ description: 'sum 相加、product 相乘' }) op: string;
  @ApiProperty({ description: '开了以后门上的数（玩家输对的那个），没开为空', nullable: true }) value: number | null;
}

// 门上的数改写这一关的那一处：值 = 门上的数 ÷ modulus 的余数 + offset。
export class ChallengeConsumeDto {
  @ApiProperty({ description: 'slot 补条件（题面里那一处写成 ?）、goal 改目标（目标柱、真出口、镜像）' }) kind: string;
  @ApiProperty({ description: '位置（slot：24 点第几张牌、八皇后第几行、数回第几格、密码破译第几行、骑士与无赖第几个人）' }) at: number;
  @ApiProperty() modulus: number;
  @ApiProperty() offset: number;
}

export class ChallengeLevelDto {
  @ApiProperty({ description: '关卡 id（加试题是 xa、xb…）' }) id: string;
  @ApiProperty({ description: '游戏 id' }) game: string;
  @ApiProperty({ description: '档位 entry、easy、normal、hard、expert' }) tier: string;
  @ApiProperty({ description: '难度分 1–10（按预计用时取对数）' }) difficulty: number;
  @ApiProperty({ description: '预计用时，秒' }) expected: number;
  @ApiProperty({ description: '收哪几关的碎片', type: [String] }) inputs: string[];
  @ApiProperty({ description: '碎片进哪一关的门，没有为空', nullable: true }) output: string | null;
  @ApiProperty({ description: '这一关碎片的字母（A、B…），加试题为空', nullable: true }) letter: string | null;
  @ApiProperty({ description: 'locked、gated（碎片齐了、门没开）、open、solved、failed' }) state: string;
  @ApiProperty({ description: '交过几次（下一次的 attempt）' }) submissions: number;
  @ApiProperty({ description: '错交次数' }) errors: number;
  @ApiProperty({ description: '要用最少步数时的最少步数，不要求为空', nullable: true }) minimum: number | null;
  @ApiProperty({ type: ChallengeGateDto, nullable: true }) gate: ChallengeGateDto | null;
  @ApiProperty({ type: ChallengeConsumeDto, nullable: true }) consume: ChallengeConsumeDto | null;
  @ApiProperty({ description: '加试题是为哪一关加的，平常为空', nullable: true }) extraOf: string | null;
  @ApiProperty({ description: '题面，开着或过了（可以重做看碎片）时给', nullable: true }) puzzle: unknown;
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
  @ApiProperty({ description: '门与终章输错扣的秒数合计（到点时刻已往前挪）' }) penaltySeconds: number;
  @ApiProperty({ description: '终章：locked 还有关没过（含加试题）、ready 能输最终密码、cleared 输对了' }) final: string;
  @ApiProperty({ type: [ChallengeLevelDto] }) levels: ChallengeLevelDto[];
  @ApiProperty({ type: ChallengeResultDto, nullable: true }) result: ChallengeResultDto | null;
}

export class ChallengeAnswerDto {
  @ApiProperty({ description: '这次交的对不对（重发的号回原来的结果）' }) correct: boolean;
  @ApiProperty({ description: '解开后给的碎片（只在这次回复里给，局面里不再给），加试题为空', nullable: true }) fragment: number | null;
  @ApiProperty({ description: '这一关解得快得不正常时追加的加试题，没有为空', nullable: true }) extra: string | null;
  @ApiProperty({ type: ChallengeRunDto }) run: ChallengeRunDto;
}

export class ChallengeGateParamDto extends ChallengeRunParamDto {
  @ApiProperty({ description: '门后面那一关的 id' }) @Matches(/^[a-p]$/) levelId: string;
}

// 门上的数或终章的最终密码。
export class ChallengeGateBodyDto {
  @ApiProperty({ description: '输入的数' }) @IsInt() @Min(0) @Max(99_999_999) value: number;
}

export class ChallengeGateResultDto {
  @ApiProperty({ description: '对不对（错了扣时间）' }) correct: boolean;
  @ApiProperty({ type: ChallengeRunDto }) run: ChallengeRunDto;
}
