import { CallHandler, ExecutionContext, Injectable, NestInterceptor } from '@nestjs/common';
import type { Request } from 'express';
import { catchError, Observable, throwError } from 'rxjs';

import { accountDeletedCanonical, base64url } from 'src/common/crypto/relay_crypto';
import { RelaySigner } from 'src/common/crypto/relay_signer';
import { RelayCode, RelayError } from 'src/common/relay_error';

// [人工决策-2026-11-17 21:24:25] 「账号已注销」带服务器签名（用户选「只给两类关键回复加认证」）：客户端收到 410 ACCOUNT_DELETED 会不可逆地清掉本机那个账号的私信
// 与私信身份私钥，明文 HTTP 下同一网络里的人伪造一条就够了。所以这条回复另带 proof：服务器在线签名钥（src/common/crypto/relay_signer.ts）对
// relay_crypto.ts 的 accountDeletedCanonical（这把设备密钥的设备号与这次请求的随机数 x-sxd-nonce）的签名。随机数由客户端每次新起、验签通过后才占用，
// 截下来的旧证明换一次请求就验不过（防重放）；客户端验过才清，没有或验不过当连不上、什么也不删（lib/relay/relay_client.dart 的 _call）。
// 只挂在账号模块的控制器上：只有它回 ACCOUNT_DELETED（AccountService.missing），设备签名守卫在拦截器之前已核过设备号与随机数。
@Injectable()
export class AccountDeletedProof implements NestInterceptor {
  constructor(private readonly signer: RelaySigner) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const request = context.switchToHttp().getRequest<Request & { deviceId?: string }>();
    return next.handle().pipe(catchError((error: unknown) => throwError(() => (error instanceof RelayError && error.code === RelayCode.accountDeleted ? this.prove(error, request) : error))));
  }

  private prove(error: RelayError, request: Request & { deviceId?: string }) {
    const proof = base64url(this.signer.sign(accountDeletedCanonical(request.deviceId!, request.header('x-sxd-nonce')!)));
    return new RelayError(error.code, error.status, error.message, { ...error.extra, proof });
  }
}
