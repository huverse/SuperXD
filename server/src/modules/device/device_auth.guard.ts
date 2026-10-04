import { CanActivate, createParamDecorator, ExecutionContext, HttpStatus, Inject, Injectable, Logger, SetMetadata } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { Request } from 'express';
import Redis from 'ioredis';

import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys, RedisKeyTTL } from 'src/common/redis/redis_keys';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { clockSkewMs } from 'src/common/relay_limits';
import { decodeBase64url, deviceIdOf, ed25519Key, requestCanonical, verifyEd25519 } from 'src/common/crypto/relay_crypto';
import { DeviceService } from 'src/modules/device/device.service';

// 注册接口自带公钥：用请求体里的签名公钥验签，并核对它与设备号一致。
const selfSignedKey = 'relay:self_signed';
export const SelfSigned = () => SetMetadata(selfSignedKey, true);

type SignedRequest = Request & { rawBody?: Buffer; deviceId?: string };

export const CurrentDevice = createParamDecorator((_: unknown, context: ExecutionContext) => context.switchToHttp().getRequest<SignedRequest>().deviceId!);

// 每个请求都用设备的 Ed25519 私钥签名，不发放会话令牌：明文 HTTP 下被截获也无法冒用或重放。
@Injectable()
export class DeviceAuthGuard implements CanActivate {
  private readonly logger = new Logger('DeviceAuth');

  constructor(
    private readonly reflector: Reflector,
    private readonly devices: DeviceService,
    @Inject(REDIS) private readonly redis: Redis,
  ) {}

  async canActivate(context: ExecutionContext) {
    const request = context.switchToHttp().getRequest<SignedRequest>();
    const deviceId = request.header('x-sxd-device') ?? '', time = request.header('x-sxd-time') ?? '', nonce = request.header('x-sxd-nonce') ?? '';
    const signature = decodeBase64url(request.header('x-sxd-signature') ?? '', 64);
    if (!/^[A-Za-z0-9_-]{22}$/.test(deviceId) || !/^\d{1,16}$/.test(time) || decodeBase64url(nonce, 16) === null || signature === null) {
      throw new RelayError(RelayCode.unauthorized, HttpStatus.UNAUTHORIZED, '缺少请求签名');
    }
    const skew = Math.abs(Date.now() - Number(time));
    if (skew > clockSkewMs) throw new RelayError(RelayCode.clockSkew, HttpStatus.UNAUTHORIZED, '设备时间偏差过大', { serverTime: Date.now() });
    const key = await this.keyOf(context, request, deviceId);
    const canonical = requestCanonical(request.method, request.originalUrl, time, nonce, request.rawBody ?? Buffer.alloc(0));
    if (key === null || !verifyEd25519(key, canonical, signature)) {
      this.logger.warn(`[DeviceAuth] action=reject reason=signature deviceId=${deviceId} path=${request.path}`);
      throw new RelayError(RelayCode.unauthorized, HttpStatus.UNAUTHORIZED, '请求签名无效');
    }
    // 验签通过后才占用随机数，伪造请求无法消耗他人的随机数。
    const fresh = await this.redis.set(RedisKeys.nonce(deviceId, nonce), '1', 'EX', RedisKeyTTL.nonce, 'NX');
    if (fresh !== 'OK') throw new RelayError(RelayCode.replayed, HttpStatus.UNAUTHORIZED, '请求已处理过');
    request.deviceId = deviceId;
    if (!this.reflector.get<boolean>(selfSignedKey, context.getHandler())) {
      this.devices.touch(deviceId).catch((error) => console.error(error));
    }
    return true;
  }

  private async keyOf(context: ExecutionContext, request: SignedRequest, deviceId: string) {
    if (!this.reflector.get<boolean>(selfSignedKey, context.getHandler())) return this.devices.signKey(deviceId);
    const raw = decodeBase64url(String((request.body as { signPublicKey?: unknown } | undefined)?.signPublicKey ?? ''), 32);
    if (raw === null) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '公钥格式不正确');
    if (deviceIdOf(raw) !== deviceId) throw new RelayError(RelayCode.deviceMismatch, HttpStatus.BAD_REQUEST, '设备号与公钥不符');
    return ed25519Key(raw);
  }
}
