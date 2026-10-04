import { ApiProperty } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { ArrayMaxSize, IsArray, IsInt, IsOptional, IsString, Matches, Max, Min } from 'class-validator';

import { ackLimit, fetchLimit } from 'src/common/relay_limits';

export class SendMessageDto {
  @ApiProperty({ description: '收件设备号' }) @Matches(/^[A-Za-z0-9_-]{22}$/) to: string;
  @ApiProperty({ description: '发送方生成的消息号（UUID），重发幂等' }) @Matches(/^[0-9a-f-]{36}$/) clientId: string;
  @ApiProperty({ description: '端到端密文，base64url' }) @IsString() envelope: string;
}

export class SendMessageResultDto {
  @ApiProperty({ description: '服务端消息号' }) id: string;
  @ApiProperty({ description: '服务端收下的时刻，毫秒' }) createTime: number;
}

export class FetchMessagesQueryDto {
  @ApiProperty({ description: '从这个消息号之后取，默认从头', required: false }) @IsOptional() @Matches(/^\d{1,20}$/) after?: string;
  @ApiProperty({ description: '最多取几条，1–50，默认 50', required: false }) @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(fetchLimit) limit?: number;
}

export class InboxMessageDto {
  @ApiProperty({ description: '服务端消息号' }) id: string;
  @ApiProperty({ description: '发送方设备号' }) from: string;
  @ApiProperty({ description: '端到端密文，base64url' }) envelope: string;
  @ApiProperty({ description: '服务端收下的时刻，毫秒' }) createTime: number;
}

export class InboxDto {
  @ApiProperty({ description: '消息，按 id 升序', type: [InboxMessageDto] }) messages: InboxMessageDto[];
  @ApiProperty({ description: '是否还有更多' }) more: boolean;
}

export class AckMessagesDto {
  @ApiProperty({ description: '已妥善保存、可删除的消息号，最多 100 个', type: [String] }) @IsArray() @ArrayMaxSize(ackLimit) @Matches(/^\d{1,20}$/, { each: true }) ids: string[];
}

export class AckResultDto {
  @ApiProperty({ description: '实际删除条数' }) removed: number;
}
