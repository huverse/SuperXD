import { createHash, randomInt } from 'node:crypto';
import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { LRUCache } from 'lru-cache';

import { rateSubjectOf } from 'src/common/client_ip';
import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { rewardCampaignCacheSeconds, rewardDrawPerHour } from 'src/common/relay_limits';
import { RewardCampaignEntity } from 'src/modules/reward/reward.entity';
import { RewardRepository } from 'src/modules/reward/reward.repository';
import { RewardMode, rewardChance, rewardModes, rewardWeight } from 'src/modules/reward/reward_odds';
import * as dtos from 'src/modules/reward/reward.dto';

// 掷骰子：[0, 1) 上均匀，百万分之一精度（同 base_chance 的小数位）。单独成类，测试里可以替换。
@Injectable()
export class RewardDice {
  roll(): number {
    return randomInt(0, 1_000_000) / 1_000_000;
  }
}

// 节日抽奖（概率模型与人工决策见 reward_odds.ts）：免签名，凭客户端本机生成的随机参与号幂等；活动表很小，按编号缓存在进程内。
@Injectable()
export class RewardService {
  private readonly logger = new Logger('Reward');
  // 活动编号 → 活动行（没有的也缓存为 null，防止不存在的编号反复查库）；条目有上限、过期自然刷新。
  private readonly campaigns = new LRUCache<string, { campaign: RewardCampaignEntity | null }>({ max: 200, ttl: rewardCampaignCacheSeconds * 1000 });

  constructor(
    private readonly limiter: RateLimiter,
    private readonly repository: RewardRepository,
    private readonly dice: RewardDice,
  ) {}

  async draw(ip: string, campaignKey: string, body: dtos.RewardDrawBodyDto): Promise<dtos.RewardDrawDto> {
    const retryAfter = await this.limiter.hit('reward_draw', rateSubjectOf(ip), rewardDrawPerHour, 3600);
    if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '抽奖请求过于频繁', { retryAfter });
    const campaign = await this.campaign(campaignKey);
    const now = new Date();
    if (campaign === null || now < campaign.startsAt || now >= campaign.endsAt) return { result: 'closed', prize: null };
    const participantHash = createHash('sha256').update(body.participant).digest('hex');
    const existing = await this.repository.findDraw(campaign.id, participantHash);
    if (existing !== null) return present(existing.prize);
    const mode = campaign.mode as RewardMode;
    if (!rewardModes.includes(mode)) throw new Error(`活动 ${campaignKey} 的模式 ${campaign.mode} 不认识`);
    const weight = rewardWeight(mode, body.activeDays, Number(campaign.maxWeight));
    const chance = rewardChance(Number(campaign.baseChance), weight);
    const lucky = this.dice.roll() < chance;
    const outcome = await this.repository.draw({ campaign, participantHash, activeDays: body.activeDays, weight, chance, lucky, now });
    this.logger.log(`[Reward] action=draw campaign=${campaignKey} mode=${mode} activeDays=${body.activeDays} chance=${chance.toFixed(4)} lucky=${lucky} won=${outcome.prize !== null}`);
    return present(outcome.prize);
  }

  private async campaign(campaignKey: string): Promise<RewardCampaignEntity | null> {
    const cached = this.campaigns.get(campaignKey);
    if (cached !== undefined) return cached.campaign;
    const campaign = await this.repository.findCampaign(campaignKey);
    this.campaigns.set(campaignKey, { campaign });
    return campaign;
  }
}

const present = (prize: { kind: string; content: string; note: string } | null): dtos.RewardDrawDto =>
  prize === null ? { result: 'missed', prize: null } : { result: 'won', prize: { kind: prize.kind as dtos.RewardPrizeKind, content: prize.content, note: prize.note } };
