import { ApiProperty } from '@nestjs/swagger';
import { IsOptional, Matches } from 'class-validator';

export class AccountSignInParamDto {
  @ApiProperty({ description: '登录方式，现在只有 kingo（学校教务）' }) @Matches(/^[a-z][a-z0-9_]{0,15}$/) provider: string;
}

// 自签名（同注册设备）：请求体带这把设备密钥的两把公钥，核对通过才登记。
export class AccountSignInBodyDto {
  @ApiProperty({ description: 'Ed25519 签名公钥，base64url 无填充' }) @Matches(/^[A-Za-z0-9_-]{43}$/) signPublicKey: string;
  @ApiProperty({ description: 'X25519 加密公钥，base64url 无填充' }) @Matches(/^[A-Za-z0-9_-]{43}$/) boxPublicKey: string;
  @ApiProperty({ description: '用中转公钥封装的登录信息（教务是口令摘要），base64url 无填充，不超过 1KB' }) @Matches(/^[A-Za-z0-9_-]{82,1366}$/) sealed: string;
  @ApiProperty({ description: '上一步要验证码时给的挑战号', required: false }) @IsOptional() @Matches(/^[A-Za-z0-9_-]{22}$/) challengeId?: string;
  @ApiProperty({ description: '验证码', required: false }) @IsOptional() @Matches(/^[A-Za-z0-9]{1,8}$/) captcha?: string;
}

export class AccountCaptchaDto {
  @ApiProperty({ description: '挑战号，答题时带回，5 分钟有效' }) challengeId: string;
  @ApiProperty({ description: '验证码图片，标准 base64' }) image: string;
  @ApiProperty({ description: '图片类型，如 image/jpeg' }) contentType: string;
  @ApiProperty({ description: '给用户看的提示' }) hint: string;
}

export class AccountSignedInDto {
  @ApiProperty({ description: '账号号（随机，不带身份信息），客户端拿它做灰度分桶' }) accountId: string;
  @ApiProperty({ description: '这次是否新建了账号' }) created: boolean;
  @ApiProperty({ description: '服务器时间，毫秒' }) serverTime: number;
}

export class AccountSignInDto {
  @ApiProperty({ description: 'signedIn 登录成功，captcha 要先答验证码', enum: ['signedIn', 'captcha'] }) status: 'signedIn' | 'captcha';
  @ApiProperty({ description: '登录成功时的账号', type: AccountSignedInDto, nullable: true }) account: AccountSignedInDto | null;
  @ApiProperty({ description: '要验证码时的题目', type: AccountCaptchaDto, nullable: true }) captcha: AccountCaptchaDto | null;
}

// 设备核对与扫码授权、找回（人工决策见 account.service.ts 的 deviceSignIn）：自签名的几个请求都带这把设备密钥的两把公钥与教务确认的学号。
export class AccountDeviceBodyDto {
  @ApiProperty({ description: 'Ed25519 签名公钥，base64url 无填充' }) @Matches(/^[A-Za-z0-9_-]{43}$/) signPublicKey: string;
  @ApiProperty({ description: 'X25519 加密公钥，base64url 无填充' }) @Matches(/^[A-Za-z0-9_-]{43}$/) boxPublicKey: string;
  @ApiProperty({ description: '手机登录教务后教务确认的学号' }) @Matches(/^[A-Za-z0-9]{1,32}$/) loginId: string;
}

export class AccountDeviceSignInDto {
  @ApiProperty({ description: 'signedIn 登录成功；exists 这个学号已有账号且还有设备登着，要扫码授权或申请找回', enum: ['signedIn', 'exists'] }) status: 'signedIn' | 'exists';
  @ApiProperty({ description: '登录成功时的账号', type: AccountSignedInDto, nullable: true }) account: AccountSignedInDto | null;
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
  @ApiProperty({ description: 'pending 等旧设备批准，approved 已加进账号', enum: ['pending', 'approved'] }) state: 'pending' | 'approved';
  @ApiProperty({ description: '批准后的账号', type: AccountSignedInDto, nullable: true }) account: AccountSignedInDto | null;
}

export class AccountRecoveryDto {
  @ApiProperty({ description: '找回申请编号' }) recoveryId: string;
  @ApiProperty({ description: 'pending 等待中，granted 已生效，denied 被账号的设备拒绝，conflict 同时有别的设备在申请、为安全不生效', enum: ['pending', 'granted', 'denied', 'conflict'] }) state: 'pending' | 'granted' | 'denied' | 'conflict';
  @ApiProperty({ description: '没人拒绝时生效的时刻，毫秒' }) grantAt: number;
  @ApiProperty({ description: '生效后的账号', type: AccountSignedInDto, nullable: true }) account: AccountSignedInDto | null;
}

export class AccountRecoveryParamDto {
  @ApiProperty({ description: '找回申请编号' }) @Matches(/^\d{1,20}$/) recoveryId: string;
}

export class AccountPendingRecoveryDto {
  @ApiProperty({ description: '找回申请编号' }) recoveryId: string;
  @ApiProperty({ description: '申请时刻，毫秒' }) createdAt: number;
  @ApiProperty({ description: '没人拒绝时生效的时刻，毫秒' }) grantAt: number;
}

export class AccountSummaryDto {
  @ApiProperty({ description: '账号号' }) accountId: string;
  @ApiProperty({ description: '已有的登录方式', type: [String] }) providers: string[];
  @ApiProperty({ description: '登录着这个账号的设备密钥数' }) deviceCount: number;
  @ApiProperty({ description: '账号建立时刻，毫秒' }) createdAt: number;
  @ApiProperty({ description: '别的设备提交、等待中的找回申请（打开应用时提醒，可拒绝或批准）', type: [AccountPendingRecoveryDto] }) recoveries: AccountPendingRecoveryDto[];
}
