import { createHash, randomInt } from 'node:crypto';
import { HttpStatus, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { LRUCache } from 'lru-cache';

import { rateSubjectOf } from 'src/common/client_ip';
import { RateLimiter } from 'src/common/redis/redis.module';
import { base64url, decodeBase64url } from 'src/common/crypto/relay_crypto';
import { RelaySigner } from 'src/common/crypto/relay_signer';
import { AccountRepository } from 'src/modules/account/account.repository';
import { AccountDataHooks } from 'src/modules/account/account_data_hooks';
import { DeviceRepository } from 'src/modules/device/device.repository';
import { PointsService } from 'src/modules/points/points.service';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { rewardCampaignCacheSeconds, rewardDrawPerDevicePerHour, rewardDrawPerHour, rewardStatusPerDevicePerHour } from 'src/common/relay_limits';
import { RewardCampaignEntity } from 'src/modules/reward/reward.entity';
import { RewardRepository } from 'src/modules/reward/reward.repository';
import { RewardMode, rewardChance, rewardLevelWeight, rewardModes, rewardWeight } from 'src/modules/reward/reward_odds';
import { sealRewardPrize, sealSignedRewardPrize } from 'src/modules/reward/reward_seal';
import * as dtos from 'src/modules/reward/reward.dto';

// 掷骰子：[0, 1) 上均匀，百万分之一精度（同 base_chance 的小数位）。单独成类，测试里可以替换。
@Injectable()
export class RewardDice {
  roll(): number {
    return randomInt(0, 1_000_000) / 1_000_000;
  }
}

// 抽签人：按应用账号认（库里只存哈希，人工决策见 reward_odds.ts 的 11-15 17:59:02 那条）。
const participantOf = (accountId: string) => createHash('sha256').update(`SXD1-reward\naccount\n${accountId}`).digest('hex');

// 节日抽奖（概率模型与人工决策见 reward_odds.ts）：抽签人是设备所在的应用账号，按它幂等（库里只存它的 sha256）；活动表很小，按编号缓存在进程内。
@Injectable()
export class RewardService implements OnModuleInit {
  private readonly logger = new Logger('Reward');
  // 活动编号 → 活动行（没有的也缓存为 null，防止不存在的编号反复查库）；条目有上限、过期自然刷新。
  private readonly campaigns = new LRUCache<string, { campaign: RewardCampaignEntity | null }>({ max: 200, ttl: rewardCampaignCacheSeconds * 1000 });

  constructor(
    private readonly limiter: RateLimiter,
    private readonly repository: RewardRepository,
    private readonly dice: RewardDice,
    private readonly accounts: AccountRepository,
    private readonly devices: DeviceRepository,
    private readonly points: PointsService,
    private readonly hooks: AccountDataHooks,
    private readonly signer: RelaySigner,
  ) {}

  // 名单里记的是账号号：注销账号时连带删掉（抽签记录只存哈希，照旧活动结束后清）。
  onModuleInit() {
    this.hooks.register((manager, accountIds) => this.repository.deleteAudienceOf(manager, accountIds));
  }

  // 信里的「领取」先问这一项：open 能领、drawn 领过（再点就是 draw 取回同一结果）、closed 不在进行、ineligible 没资格（按钮不显示）、
  // too_new 账号天数不够（附 eligibleAt）、sold_out 发完为止的活动这一批领完了（补货后又是 open）。只读、不记这次。
  async status(deviceId: string, campaignKey: string, levels: boolean): Promise<dtos.RewardStatusDto> {
    const retryAfter = await this.limiter.hit('reward_status', deviceId, rewardStatusPerDevicePerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '查询过于频繁', { retryAfter });
    const campaign = await this.campaign(campaignKey);
    const now = new Date();
    if (campaign === null || now < campaign.startsAt || now >= campaign.endsAt) return { state: 'closed', endsAt: campaign?.endsAt.toISOString() ?? null, eligibleAt: null };
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    const endsAt = campaign.endsAt.toISOString();
    if ((await this.repository.findDraw(campaign.id, participantOf(accountId))) !== null) return { state: 'drawn', endsAt, eligibleAt: null };
    const gate = await this.gate(campaign, accountId, deviceId, levels, now);
    if (gate !== null) return { state: gate.state, endsAt, eligibleAt: gate.eligibleAt };
    if (campaign.distribution === 'all' && (await this.repository.unclaimed(campaign.id)) === 0) return { state: 'sold_out', endsAt, eligibleAt: null };
    return { state: 'open', endsAt, eligibleAt: null };
  }

  // 资格（人工决策见 reward_odds.ts 的 11-16 那条）：名单、最低等级、账号满几天；都过返回 null。levels 为假（娱乐与积分关着）按 Lv0。
  private async gate(campaign: RewardCampaignEntity, accountId: string, deviceId: string, levels: boolean, now: Date): Promise<{ state: 'ineligible' | 'too_new'; eligibleAt: number | null } | null> {
    if (campaign.audience === 'list' && !(await this.repository.inAudience(campaign.id, accountId))) return { state: 'ineligible', eligibleAt: null };
    if (campaign.minLevel > 0 && (levels ? await this.points.levelOfAccount(accountId) : 0) < campaign.minLevel) return { state: 'ineligible', eligibleAt: null };
    const created = await this.accounts.createdOf(deviceId);
    const eligibleAt = (created?.getTime() ?? now.getTime()) + campaign.minAccountDays * 86400_000;
    return now.getTime() < eligibleAt ? { state: 'too_new', eligibleAt } : null;
  }

  async draw(ip: string, deviceId: string, campaignKey: string, body: dtos.RewardDrawBodyDto): Promise<dtos.RewardDrawDto> {
    // 先按设备再按来源计数：一台设备刷请求先被自己的额度挡住，不占同一出口（校园网 NAT）别人的宽松档。
    const retryAfter = (await this.limiter.hit('reward_device', deviceId, rewardDrawPerDevicePerHour, 3600)) ?? (await this.limiter.hit('reward_draw', rateSubjectOf(ip), rewardDrawPerHour, 3600));
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '抽奖请求过于频繁', { retryAfter });
    const campaign = await this.campaign(campaignKey);
    const now = new Date();
    if (campaign === null || now < campaign.startsAt || now >= campaign.endsAt) return { result: 'closed', sealed: null };
    const accountId = await this.accounts.accountOf(deviceId);
    if (accountId === null) throw new RelayError(RelayCode.accountNotFound, HttpStatus.NOT_FOUND, '没有登录应用账号');
    // 按账号认人（11-15 起是自己的账号体系，没有学号可认，人工决策见 account.service.ts）；抽过的照旧回同一结果，不再看资格。
    const participantHash = participantOf(accountId);
    const existing = await this.repository.findDraw(campaign.id, participantHash);
    if (existing !== null) return this.present(existing.prize, campaignKey, deviceId, body.seal === 2);
    // 资格由活动参数定（名单、最低等级、账号满几天，人工决策见 reward_odds.ts 的 11-16 那条）；没资格与天数不够都不记这次。
    const gate = await this.gate(campaign, accountId, deviceId, body.levels !== false, now);
    if (gate?.state === 'ineligible') return { result: 'ineligible', sealed: null };
    if (gate?.state === 'too_new') throw new RelayError(RelayCode.accountTooNew, HttpStatus.FORBIDDEN, '应用账号建立不满规定天数', { eligibleAt: gate.eligibleAt });
    const mode = campaign.mode as RewardMode;
    if (!rewardModes.includes(mode)) throw new Error(`活动 ${campaignKey} 的模式 ${campaign.mode} 不认识`);
    // 等级只在加权模式里用（平权人人一样），按设备所在账号的积分算。
    // 客户端关掉了娱乐与积分（levels: false，人工决策见客户端 lib/domain/leisure.dart）时按 Lv0：只会降低自己的机会，不用防篡改。
    const level = mode === 'weighted' && body.levels !== false ? await this.points.levelOfAccount(accountId) : 0;
    const maxWeight = Number(campaign.maxWeight);
    const weight = rewardWeight(mode, body.activeDays, level, maxWeight);
    // all（有资格就发）不抽签。
    const all = campaign.distribution === 'all';
    const chance = all ? 1 : rewardChance(Number(campaign.baseChance), weight);
    const lucky = all || this.dice.roll() < chance;
    const outcome = await this.repository.draw({
      campaign,
      participantHash,
      activeDays: body.activeDays,
      weight,
      chance,
      lucky,
      levelWeight: rewardLevelWeight(mode, level, maxWeight),
      tierRoll: () => this.dice.roll(),
      now,
    });
    this.logger.log(`[Reward] action=draw campaign=${campaignKey} distribution=${campaign.distribution} mode=${mode} activeDays=${body.activeDays} level=${level} chance=${chance.toFixed(4)} lucky=${lucky} won=${outcome.prize !== null}${outcome.soldOut ? ' soldOut=true' : ''}`);
    if (outcome.soldOut) return { result: 'sold_out', sealed: null };
    return this.present(outcome.prize, campaignKey, deviceId, body.seal === 2);
  }

  // 抽中的奖品只发给抽签的这台设备：用它登记的 box 公钥封装（信封见 reward_seal.ts），同一网络里的人截不走口令。
  // signed（请求带 seal: 2）时给第 2 版：另接服务器签名，同一网络里的人伪造不了（人工决策见 reward_seal.ts 的 11-17 那条）。
  private async present(prize: { kind: string; content: string; note: string } | null, campaignKey: string, deviceId: string, signed: boolean): Promise<dtos.RewardDrawDto> {
    if (prize === null) return { result: 'missed', sealed: null };
    const [keys] = await this.devices.keysOf([deviceId]);
    const devicePublic = keys === undefined ? null : decodeBase64url(keys.boxPublicKey, 32);
    if (devicePublic === null) throw new Error(`设备 ${deviceId} 没有可用的加密公钥`);
    const sealed = signed ? sealSignedRewardPrize(prize, campaignKey, deviceId, devicePublic, (message) => this.signer.sign(message)) : sealRewardPrize(prize, campaignKey, deviceId, devicePublic);
    return { result: 'won', sealed: base64url(sealed) };
  }

  private async campaign(campaignKey: string): Promise<RewardCampaignEntity | null> {
    const cached = this.campaigns.get(campaignKey);
    if (cached !== undefined) return cached.campaign;
    const campaign = await this.repository.findCampaign(campaignKey);
    this.campaigns.set(campaignKey, { campaign });
    return campaign;
  }
}

