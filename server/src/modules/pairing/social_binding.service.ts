import { HttpStatus, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { DataSource } from 'typeorm';

import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { socialBindPerHour } from 'src/common/relay_limits';
import { decodeBase64url, deviceIdOf, ed25519Key, socialBindCanonical, verifyEd25519 } from 'src/common/crypto/relay_crypto';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';
import { AccountRepository } from 'src/modules/account/account.repository';
import { DeviceRepository } from 'src/modules/device/device.repository';
import { DeviceService } from 'src/modules/device/device.service';
import { FriendshipRepository } from 'src/modules/friend/friendship.repository';
import { MessageRepository } from 'src/modules/message/message.repository';
import { AccountSocialRepository } from 'src/modules/pairing/account_social.repository';
import * as dtos from 'src/modules/pairing/pairing.dto';

// 私信挂到应用账号（第 4 阶段，人工决策见客户端 lib/social/social_service.dart 文件头 11-14 的两条）：一个账号同一时刻只有一台私信设备。
// 请求用应用账号的设备密钥签名，请求体带私信设备的公钥与它对两把钥匙的签名（socialBindCanonical），证明两把钥匙在同一台手机上；
// 私信设备不存在就顺带登记（新手机、被接管后再拿回来的旧手机都走这里，不另外注册）。
// 账号的私信在另一台设备上时，不带 takeover 回 SOCIAL_ELSEWHERE；带了就接管：在同一个事务里把好友关系改挂到这台（对方那行记下旧号，
// 对方客户端据此提示「对方换了设备」），删掉旧设备和它没收的信（密文给旧设备的密钥，新设备解不开）。旧手机之后的请求是 UNAUTHORIZED，
// 它重新挂账号时得到 SOCIAL_ELSEWHERE，显示私信在另一台手机上。注销账号时私信设备连同好友关系与信箱一起删（[人工决策-2026-11-14 17:56:46] 用户选「一并删除」）。
@Injectable()
export class SocialBindingService implements OnModuleInit {
  private readonly logger = new Logger('SocialBinding');

  constructor(
    private readonly dataSource: DataSource,
    private readonly limiter: RateLimiter,
    private readonly accounts: AccountRepository,
    private readonly socials: AccountSocialRepository,
    private readonly devices: DeviceRepository,
    private readonly deviceService: DeviceService,
    private readonly friendships: FriendshipRepository,
    private readonly messages: MessageRepository,
    private readonly hooks: AccountDataHooks,
  ) {}

  onModuleInit() {
    this.hooks.register(async (manager, accountIds) => {
      const deviceIds = await this.socials.deleteAccounts(accountIds, manager);
      if (deviceIds.length === 0) return;
      await this.friendships.removeAllOf(deviceIds, manager);
      await this.messages.removeMailboxes(deviceIds, manager);
      await this.devices.remove(deviceIds, manager);
      this.deviceService.forget(deviceIds);
      this.logger.log(`[SocialBinding] action=delete_accounts devices=${deviceIds.length}`);
    });
  }

  async bind(accountDeviceId: string, body: dtos.BindSocialDto): Promise<dtos.BindSocialResultDto> {
    const retryAfter = await this.limiter.hit('social_bind', accountDeviceId, socialBindPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '请求过于频繁', { retryAfter });
    const accountId = await this.accounts.accountOf(accountDeviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    const sign = decodeBase64url(body.signPublicKey, 32), box = decodeBase64url(body.boxPublicKey, 32), proof = decodeBase64url(body.proof, 64);
    if (sign === null || box === null || proof === null) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '公钥或凭证格式不正确');
    const deviceId = deviceIdOf(sign);
    if (!verifyEd25519(ed25519Key(sign), socialBindCanonical(accountDeviceId, deviceId), proof)) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '私信设备的凭证不对');
    // 应用账号的设备密钥不能兼作私信设备（两者分开，退出应用账号删的是那把账号密钥）。
    if (deviceId === accountDeviceId || (await this.accounts.accountOf(deviceId)) !== null) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '私信设备不能是应用账号的设备密钥');
    await this.deviceService.enroll(deviceId, body.signPublicKey, body.boxPublicKey);
    const previous = await this.dataSource.transaction(async (manager) => {
      const current = await this.socials.lockOf(accountId, manager);
      const owner = await this.socials.ownerOf(deviceId, manager);
      if (owner !== null && owner !== accountId) throw new RelayError(RelayCode.socialTaken, HttpStatus.CONFLICT, '这个私信设备属于别的应用账号');
      if (current === deviceId) return null;
      if (current !== null && body.takeover !== true) throw new RelayError(RelayCode.socialElsewhere, HttpStatus.CONFLICT, '这个应用账号的私信在另一台设备上');
      if (current !== null) {
        await this.friendships.moveDevice(current, deviceId, manager);
        await this.messages.removeMailboxes([current], manager);
        await this.devices.remove([current], manager);
      }
      await this.socials.set(accountId, deviceId, manager);
      return current;
    });
    if (previous !== null) this.deviceService.forget([previous]);
    this.logger.log(`[SocialBinding] action=bind deviceId=${deviceId} accountDeviceId=${accountDeviceId} moved=${previous !== null}`);
    return { deviceId, moved: previous !== null };
  }
}
