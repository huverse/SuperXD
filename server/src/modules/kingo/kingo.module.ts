import { Module } from '@nestjs/common';

import { HttpKingoVerifier, KingoVerifier } from 'src/modules/kingo/kingo_verifier';

// 学校教务协议的适配：只会登录一次、读身份页拿学号，不知道应用账号；应用账号的登录方式经端口 KingoVerifier 使用。
@Module({
  providers: [{ provide: KingoVerifier, useClass: HttpKingoVerifier }],
  exports: [KingoVerifier],
})
export class KingoModule {}
