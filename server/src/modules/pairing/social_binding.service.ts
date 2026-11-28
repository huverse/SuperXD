import { HttpStatus, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { DataSource, QueryFailedError } from 'typeorm';

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
    // [人工决策-2026-11-15 21:48:25] 凭恢复码重设时私信一起收回（用户选「同时解绑私信，按最佳实践做」）：只删私信设备的登记，它就连不上中转、收不到新信；
    // 好友关系、没收的信与账号的挂载都留着：私信本来就在发起重设的手机上的，照现有流程重新挂上同一台就恢复；在被踢的手机上的，发起重设的手机照现有流程接管，
    // 好友那边提示换了设备。同大厂重设密码后撤销所有会话、消息端要重新验证的做法。
    this.hooks.registerRevoke(async (manager, accountIds) => {
      const deviceIds = await this.socials.devicesOf(accountIds, manager);
      if (deviceIds.length === 0) return;
      await this.devices.remove(deviceIds, manager);
      this.deviceService.forget(deviceIds);
      this.logger.log(`[SocialBinding] action=revoke devices=${deviceIds.length}`);
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
    const taken = () => new RelayError(RelayCode.socialTaken, HttpStatus.CONFLICT, '这个私信设备属于别的应用账号');
    // 两个账号同时挂同一台私信设备时，InnoDB 可能判成死锁（两边锁账号行留下的间隙锁与插入互等，MySQL 要求重试事务）：
    // 只对死锁（errno 1213）重来一次，重来时已能看到对方挂上的那一行，照常回 SOCIAL_TAKEN，不回 500。11-16 CI 偶发复现过。
    const deadlocked = (error: unknown) => error instanceof QueryFailedError && (error.driverError as { errno?: number }).errno === 1213;
    const attempt = () => this.dataSource.transaction(async (manager) => {
      // 账号写入门禁（11-28 审查 F05）：先锁账号行，注销与挂私信按它串行。
      await this.accounts.hold(manager, accountId);
      const current = await this.socials.lockOf(accountId, manager);
      const owner = await this.socials.ownerOf(deviceId, manager);
      if (owner !== null && owner !== accountId) throw taken();
      if (current !== null && current !== deviceId && body.takeover !== true) throw new RelayError(RelayCode.socialElsewhere, HttpStatus.CONFLICT, '这个应用账号的私信在另一台设备上');
      // 检查都过了才登记私信设备：原来先登记再检查，被拒的请求也留下一台设备，一把账号密钥就能绕过设备注册限流往 device 表写行。
      await this.deviceService.enroll(deviceId, body.signPublicKey, body.boxPublicKey);
      if (current === deviceId) return null;
      if (current !== null) {
        await this.friendships.moveDevice(current, deviceId, manager);
        await this.messages.removeMailboxes([current], manager);
        await this.devices.remove([current], manager);
      }
      // 两个账号同时挂同一台私信设备：后到的撞 uk_device，回 SOCIAL_TAKEN（事务回滚），不回 500、也不会挂进别人的那一行。
      if (!(await this.socials.set(accountId, deviceId, current !== null, manager))) throw taken();
      return current;
    });
    const previous = await attempt().catch((error: unknown) => {
      if (!deadlocked(error)) throw error;
      this.logger.warn(`[SocialBinding] action=bind_deadlock_retry deviceId=${deviceId}`);
      return attempt();
    });
    if (previous !== null) this.deviceService.forget([previous]);
    this.logger.log(`[SocialBinding] action=bind deviceId=${deviceId} accountDeviceId=${accountDeviceId} moved=${previous !== null}`);
    return { deviceId, moved: previous !== null };
  }
}
