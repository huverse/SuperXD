import { ApiProperty } from '@nestjs/swagger';
import { Matches } from 'class-validator';

export class CreateInviteDto {
  @ApiProperty({ description: '邀请号，客户端随机 16 字节 base64url' }) @Matches(/^[A-Za-z0-9_-]{22}$/) inviteId: string;
  @ApiProperty({ description: '邀请 Ed25519 公钥 base64url；私钥只在二维码里' }) @Matches(/^[A-Za-z0-9_-]{43}$/) publicKey: string;
}

export class CreateInviteResultDto {
  @ApiProperty({ description: '邀请号' }) inviteId: string;
  @ApiProperty({ description: '过期时刻，毫秒' }) expiresAt: number;
}
