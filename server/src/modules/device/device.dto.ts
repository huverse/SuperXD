import { ApiProperty } from '@nestjs/swagger';
import { Matches } from 'class-validator';

export class RegisterDeviceDto {
  @ApiProperty({ description: 'Ed25519 签名公钥，base64url 无填充' }) @Matches(/^[A-Za-z0-9_-]{43}$/) signPublicKey: string;
  @ApiProperty({ description: 'X25519 加密公钥，base64url 无填充' }) @Matches(/^[A-Za-z0-9_-]{43}$/) boxPublicKey: string;
}

export class RegisterDeviceResultDto {
  @ApiProperty({ description: '设备号' }) deviceId: string;
  @ApiProperty({ description: '服务器时间，毫秒' }) serverTime: number;
}
