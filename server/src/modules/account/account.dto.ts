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

export class AccountSummaryDto {
  @ApiProperty({ description: '账号号' }) accountId: string;
  @ApiProperty({ description: '已有的登录方式', type: [String] }) providers: string[];
  @ApiProperty({ description: '登录着这个账号的设备密钥数' }) deviceCount: number;
  @ApiProperty({ description: '账号建立时刻，毫秒' }) createdAt: number;
}
