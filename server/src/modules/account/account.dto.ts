import { ApiProperty } from '@nestjs/swagger';
import { Matches } from 'class-validator';

// 自签名的几个请求（注册、登录、用恢复码重设、出示扫码登录的二维码）都带这把设备密钥的两把公钥，核对通过才登记。
export class AccountDeviceKeysDto {
  @ApiProperty({ description: 'Ed25519 签名公钥，base64url 无填充' }) @Matches(/^[A-Za-z0-9_-]{43}$/) signPublicKey: string;
  @ApiProperty({ description: 'X25519 加密公钥，base64url 无填充' }) @Matches(/^[A-Za-z0-9_-]{43}$/) boxPublicKey: string;
}

// 注册、登录、用恢复码重设：用户名不分大小写（服务器存小写），密码等秘密在 sealed 里（见 account_keys.ts 的信封）。
// sealed 的明文 JSON：注册 {password, recoveryCode}，登录 {password}，重设 {recoveryCode, password, newRecoveryCode}。
export class AccountCredentialBodyDto extends AccountDeviceKeysDto {
  @ApiProperty({ description: '用户名，3–20 位字母、数字或下划线' }) @Matches(/^[A-Za-z0-9_]{3,20}$/) username: string;
  @ApiProperty({ description: '用中转公钥封装的秘密，base64url 无填充，不超过 1KB' }) @Matches(/^[A-Za-z0-9_-]{82,1366}$/) sealed: string;
}

// 登录着改密码（明文 {password}）或换恢复码（明文 {recoveryCode}）。
export class AccountSecretBodyDto {
  @ApiProperty({ description: '用中转公钥封装的新秘密，base64url 无填充，不超过 1KB' }) @Matches(/^[A-Za-z0-9_-]{82,1366}$/) sealed: string;
}

export class AccountSignedInDto {
  @ApiProperty({ description: '账号号（随机，不带身份信息），客户端拿它做灰度分桶' }) accountId: string;
  @ApiProperty({ description: '用户名（小写）' }) username: string;
  @ApiProperty({ description: '服务器时间，毫秒' }) serverTime: number;
}

export class AccountJoinDto {
  @ApiProperty({ description: '票据号，放进二维码' }) ticketId: string;
  @ApiProperty({ description: '6 位核对码，新旧两台设备上都显示' }) code: string;
  @ApiProperty({ description: '过期时刻，毫秒' }) expiresAt: number;
}

export class AccountJoinParamDto {
  @ApiProperty({ description: '票据号' }) @Matches(/^[A-Za-z0-9_-]{22}$/) ticketId: string;
}

export class AccountJoinApproveBodyDto {
  @ApiProperty({ description: '二维码里的核对码' }) @Matches(/^\d{6}$/) code: string;
}

export class AccountJoinStateDto {
  @ApiProperty({ description: 'pending 等已登录的设备批准，approved 已登录', enum: ['pending', 'approved'] }) state: 'pending' | 'approved';
  @ApiProperty({ description: '批准后的账号', type: AccountSignedInDto, nullable: true }) account: AccountSignedInDto | null;
}

export class AccountSummaryDto {
  @ApiProperty({ description: '账号号' }) accountId: string;
  @ApiProperty({ description: '用户名（小写）' }) username: string;
  @ApiProperty({ description: '登录着这个账号的设备密钥数' }) deviceCount: number;
  @ApiProperty({ description: '账号建立时刻，毫秒' }) createdAt: number;
}
