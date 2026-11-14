import { ApiProperty } from '@nestjs/swagger';
import { IsBoolean, IsOptional, Matches } from 'class-validator';

export class BindSocialDto {
  @ApiProperty({ description: '私信设备的 Ed25519 签名公钥，base64url 无填充' }) @Matches(/^[A-Za-z0-9_-]{43}$/) signPublicKey: string;
  @ApiProperty({ description: '私信设备的 X25519 加密公钥，base64url 无填充' }) @Matches(/^[A-Za-z0-9_-]{43}$/) boxPublicKey: string;
  @ApiProperty({ description: '私信密钥对「SXD1-social-bind\\n应用账号设备号\\n私信设备号」的签名，base64url' }) @Matches(/^[A-Za-z0-9_-]{86}$/) proof: string;
  @ApiProperty({ description: '账号的私信在别的设备上时，是否由这台接管', required: false }) @IsOptional() @IsBoolean() takeover?: boolean;
}

export class BindSocialResultDto {
  @ApiProperty({ description: '私信设备号' }) deviceId: string;
  @ApiProperty({ description: '这次是否从别的设备接管过来（好友关系已改挂到这台）' }) moved: boolean;
}
