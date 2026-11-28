import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';

import { RewardCampaignEntity, RewardDrawEntity, RewardPrizeEntity } from 'src/modules/reward/reward.entity';
import { rewardPickTier, rewardReleased } from 'src/modules/reward/reward_odds';

// soldOut：发完为止（all）的活动这一批发完了，这次没记（补货后还能来领，人工决策见 reward_odds.ts 的 11-18 那条）。
export type RewardDrawOutcome = { prize: Pick<RewardPrizeEntity, 'kind' | 'content' | 'note'> | null; soldOut?: true };

export type RewardDrawInput = {
  campaign: RewardCampaignEntity;
  participantHash: string;
  activeDays: number;
  weight: number;
  chance: number;
  // 骰子已经掷出抽中；还要看这一小时的放量额度与库存。
  lucky: boolean;
  // 等级的倍数（挑档时大额档乘它）与挑档用的骰子（不止一档有额度时才掷）。
  levelWeight: number;
  tierRoll: () => number;
  now: Date;
};

export abstract class RewardRepository {
  abstract findCampaign(campaignKey: string): Promise<RewardCampaignEntity | null>;
  // 这台设备（participantHash 是设备号的 sha256）在这次活动里抽过的结果；没抽过为空。
  abstract findDraw(campaignId: string, participantHash: string): Promise<RewardDrawOutcome | null>;
  // 记一次抽签并按需发奖，同一事务；同一台设备并发来两次只记一次，后到的拿先到的结果。
  abstract draw(input: RewardDrawInput): Promise<RewardDrawOutcome>;
  // 还没发出去的奖品份数（发完为止的活动查状态用；读每档的计数 reward_tier_stock，行数是档数）。
  abstract unclaimed(campaignId: string): Promise<number>;
  // 这个账号在不在这次活动的名单里（走 uk_campaign_account）。
  abstract inAudience(campaignId: string, accountId: string): Promise<boolean>;
  // 删这些账号在名单里的行（调用方事务内）：注销账号。
  abstract deleteAudienceOf(manager: EntityManager, accountIds: string[]): Promise<void>;
  // 删除结束早于 before 的活动的奖品与抽签记录，每次最多 limit 行；都删完的活动行一并删掉。返回删除行数。
  abstract deleteEnded(before: Date, limit: number): Promise<number>;
}

@Injectable()
export class TypeormRewardRepository extends RewardRepository {
  constructor(@InjectRepository(RewardCampaignEntity) private readonly campaigns: Repository<RewardCampaignEntity>) {
    super();
  }

  findCampaign(campaignKey: string) {
    return this.campaigns.findOne({ where: { campaignKey } });
  }

  async findDraw(campaignId: string, participantHash: string) {
    return this.outcome(this.campaigns.manager, campaignId, participantHash);
  }

  private async outcome(manager: EntityManager, campaignId: string, participantHash: string): Promise<RewardDrawOutcome | null> {
    const rows = (await manager.query(
      'SELECT d.prize_id AS prizeId, p.kind, p.content, p.note FROM reward_draw d LEFT JOIN reward_prize p ON p.id = d.prize_id WHERE d.campaign_id = ? AND d.participant_hash = ?',
      [campaignId, participantHash],
    )) as { prizeId: string | null; kind: string | null; content: string | null; note: string | null }[];
    const row = rows[0];
    if (row === undefined) return null;
    return { prize: row.prizeId === null ? null : { kind: row.kind!, content: row.content!, note: row.note! } };
  }

  async draw(input: RewardDrawInput) {
    const { campaign, now } = input;
    return this.campaigns.manager.transaction(async (manager: EntityManager) => {
      const inserted = (await manager.query(
        'INSERT IGNORE INTO reward_draw (campaign_id, participant_hash, active_days, weight, chance, prize_id, create_time, update_time) VALUES (?, ?, ?, ?, ?, NULL, ?, ?)',
        [campaign.id, input.participantHash, input.activeDays, input.weight.toFixed(2), input.chance.toFixed(6), now, now],
      )) as { affectedRows: number; insertId: number | string };
      if (inserted.affectedRows === 0) return (await this.outcome(manager, campaign.id, input.participantHash))!;
      if (!input.lucky) return { prize: null };
      // 抽中的人在活动这一行上排队，放量额度与发奖一个接一个算；只有抽中的才排，人数有界。
      await manager.query('SELECT id FROM reward_campaign WHERE id = ? FOR UPDATE', [campaign.id]);
      // 每档各自均匀放量：这一小时每档还能发的份数，再按等级加权挑一档。读每档一行的计数（11-28 审查 F07：原来汇总这次活动的全部奖品行，工作量随库存增长），
      // 行数是档数；导入与发出时在同一事务里改它（见 reward_admin.ts 的 import 与下面发出时）。
      const counts = (await manager.query('SELECT tier, stock, given FROM reward_tier_stock WHERE campaign_id = ?', [campaign.id])) as { tier: number; stock: number; given: number }[];
      // all（有资格就发）不按小时放量，发完为止。
      const released = (stock: number) => (campaign.distribution === 'all' ? stock : rewardReleased(stock, campaign.startsAt, campaign.endsAt, now));
      const available = counts.map((row) => ({ tier: Number(row.tier), count: Math.max(0, released(Number(row.stock)) - Number(row.given)) }));
      const open = available.filter((item) => item.count > 0);
      const tier = open.length > 1 ? rewardPickTier(open, input.levelWeight, input.tierRoll()) : (open[0]?.tier ?? null);
      if (tier === null) return this.empty(manager, campaign.distribution, inserted.insertId);
      const [prize] = (await manager.query('SELECT id, kind, content, note FROM reward_prize WHERE campaign_id = ? AND tier = ? AND draw_id IS NULL ORDER BY id LIMIT 1 FOR UPDATE', [campaign.id, tier])) as {
        id: string;
        kind: string;
        content: string;
        note: string;
      }[];
      if (prize === undefined) return this.empty(manager, campaign.distribution, inserted.insertId);
      const drawId = String(inserted.insertId);
      await manager.query('UPDATE reward_prize SET draw_id = ?, update_time = ? WHERE id = ?', [drawId, now, prize.id]);
      await manager.query('UPDATE reward_draw SET prize_id = ?, update_time = ? WHERE id = ?', [prize.id, now, drawId]);
      await manager.query('UPDATE reward_tier_stock SET given = given + 1, update_time = ? WHERE campaign_id = ? AND tier = ?', [now, campaign.id, tier]);
      return { prize: { kind: prize.kind, content: prize.content, note: prize.note } };
    });
  }

  // 没有可发的了：抽签（lottery）照旧记成没抽中；发完为止（all）撤掉这次的记录、报这一批领完了，补货后同一个人还能来领。
  private async empty(manager: EntityManager, distribution: string, drawId: number | string): Promise<RewardDrawOutcome> {
    if (distribution !== 'all') return { prize: null };
    await manager.query('DELETE FROM reward_draw WHERE id = ?', [drawId]);
    return { prize: null, soldOut: true };
  }

  async unclaimed(campaignId: string) {
    const [row] = (await this.campaigns.query('SELECT COALESCE(SUM(stock - given), 0) AS count FROM reward_tier_stock WHERE campaign_id = ?', [campaignId])) as { count: string }[];
    return Number(row.count);
  }

  async inAudience(campaignId: string, accountId: string) {
    const rows = (await this.campaigns.query('SELECT 1 AS found FROM reward_audience WHERE campaign_id = ? AND account_id = ? LIMIT 1', [campaignId, accountId])) as unknown[];
    return rows.length > 0;
  }

  async deleteAudienceOf(manager: EntityManager, accountIds: string[]) {
    if (accountIds.length === 0) return;
    await manager.query('DELETE FROM reward_audience WHERE account_id IN (?)', [accountIds]);
  }

  async deleteEnded(before: Date, limit: number) {
    const ended = (await this.campaigns.query('SELECT id FROM reward_campaign WHERE ends_at < ? ORDER BY ends_at LIMIT 20', [before])) as { id: string }[];
    let removed = 0;
    for (const { id } of ended) {
      if (removed >= limit) break;
      const draws = (await this.campaigns.query('DELETE FROM reward_draw WHERE campaign_id = ? LIMIT ?', [id, limit - removed])) as { affectedRows: number };
      removed += draws.affectedRows;
      if (removed >= limit) break;
      const prizes = (await this.campaigns.query('DELETE FROM reward_prize WHERE campaign_id = ? LIMIT ?', [id, limit - removed])) as { affectedRows: number };
      removed += prizes.affectedRows;
      if (removed >= limit) break;
      const audience = (await this.campaigns.query('DELETE FROM reward_audience WHERE campaign_id = ? LIMIT ?', [id, limit - removed])) as { affectedRows: number };
      removed += audience.affectedRows;
      if (removed >= limit) break;
      // 每档一行的计数，最多 10 行。
      const stocks = (await this.campaigns.query('DELETE FROM reward_tier_stock WHERE campaign_id = ?', [id])) as { affectedRows: number };
      removed += stocks.affectedRows;
      await this.campaigns.delete({ id });
      removed++;
    }
    return removed;
  }
}
