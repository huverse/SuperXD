import { ApiProperty } from '@nestjs/swagger';
import { IsString, Matches } from 'class-validator';

// base64url 的密文；超长一律 413：请求体在进路由前按 8KB 封顶，解码后的字节数在 service 里按 2KB 再查。
export class SubmitChaoxingPackDto {
  @ApiProperty({ description: '一次性密钥加密后的凭据包，base64url，不超过 2KB' }) @IsString() data: string;
}

export class SubmitChaoxingPackResultDto {
  @ApiProperty({ description: '取件号，交给对方来取' }) id: string;
  @ApiProperty({ description: '过期时刻，毫秒' }) expiresAt: number;
  @ApiProperty({ description: '作废口令，只给出示方这一次，换码时凭它作废这张' }) revokeToken: string;
}

export class PickupChaoxingPackParamDto {
  @ApiProperty({ description: '取件号' }) @Matches(/^[A-Za-z0-9_-]{16}$/) id: string;
}

export class RevokeChaoxingPackDto {
  @ApiProperty({ description: '投递时拿到的作废口令' }) @Matches(/^[A-Za-z0-9_-]{22}$/) token: string;
}

export class PickupChaoxingPackResultDto {
  @ApiProperty({ description: '加密后的凭据包，base64url' }) data: string;
}
