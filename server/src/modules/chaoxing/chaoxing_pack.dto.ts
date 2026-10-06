import { ApiProperty } from '@nestjs/swagger';
import { IsString, Matches, MaxLength } from 'class-validator';

import { chaoxingPackMaxBytes } from 'src/common/relay_limits';

// base64url 的密文；长度上限按字节算在 service 里再查一次。
export class SubmitChaoxingPackDto {
  @ApiProperty({ description: '一次性密钥加密后的凭据包，base64url，不超过 2KB' }) @IsString() @MaxLength(chaoxingPackMaxBytes * 2) data: string;
}

export class SubmitChaoxingPackResultDto {
  @ApiProperty({ description: '取件号，交给对方来取' }) id: string;
  @ApiProperty({ description: '过期时刻，毫秒' }) expiresAt: number;
}

export class PickupChaoxingPackParamDto {
  @ApiProperty({ description: '取件号' }) @Matches(/^[A-Za-z0-9_-]{16}$/) id: string;
}

export class PickupChaoxingPackResultDto {
  @ApiProperty({ description: '加密后的凭据包，base64url' }) data: string;
}
