import { ApiProperty } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { IsString, Matches, ValidateNested } from 'class-validator';

export class FriendDto {
  @ApiProperty({ description: '好友设备号' }) deviceId: string;
  @ApiProperty({ description: '成为好友的时刻，毫秒' }) since: number;
}

export class FriendListDto {
  @ApiProperty({ description: '好友列表，最多 500 个', type: [FriendDto] }) friends: FriendDto[];
}

export class HelloDto {
  @ApiProperty({ description: '发送方生成的消息号（UUID）' }) @Matches(/^[0-9a-f-]{36}$/) clientId: string;
  // 长度由请求体上限兜底，解码后的字节数由服务按密文上限判定（ENVELOPE_TOO_LARGE）。
  @ApiProperty({ description: '给邀请人的端到端密文（含扫码方公钥与昵称），base64url' }) @IsString() envelope: string;
}

export class RedeemInviteDto {
  @ApiProperty({ description: '邀请号' }) @Matches(/^[A-Za-z0-9_-]{22}$/) inviteId: string;
  @ApiProperty({ description: '邀请凭证：邀请私钥对“邀请号+扫码方设备号”的签名，base64url' }) @Matches(/^[A-Za-z0-9_-]{86}$/) proof: string;
  @ApiProperty({ description: '投递给邀请人的问候密文', type: HelloDto }) @ValidateNested() @Type(() => HelloDto) hello: HelloDto;
}

export class RedeemInviteResultDto {
  @ApiProperty({ description: '邀请人设备号' }) deviceId: string;
  @ApiProperty({ description: '成为好友的时刻，毫秒' }) since: number;
}
