import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';

import { RewardCampaignEntity, RewardDrawEntity, RewardPrizeEntity } from 'src/modules/reward/reward.entity';
import { rewardReleased } from 'src/modules/reward/reward_odds';

export type RewardDrawOutcome = { prize: Pick<RewardPrizeEntity, 'kind' | 'content' | 'note'> | null };

export type RewardDrawInput = {
  campaign: RewardCampaignEntity;
  participantHash: string;
  activeDays: number;
  weight: number;
  chance: number;
  // 骰子已经掷出抽中；还要看这一小时的放量额度与库存。
  lucky: boolean;
  now: Date;
};

export abstract class RewardRepository {
  abstract findCampaign(campaignKey: string): Promise<RewardCampaignEntity | null>;
  // 这个参与号在这次活动里抽过的结果；没抽过为空。
  abstract findDraw(campaignId: string, participantHash: string): Promise<RewardDrawOutcome | null>;
  // 记一次抽签并按需发奖，同一事务；同一参与号并发来两次只记一次，后到的拿先到的结果。
  abstract draw(input: RewardDrawInput): Promise<RewardDrawOutcome>;
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
      const [counts] = (await manager.query('SELECT COUNT(*) AS stock, COUNT(draw_id) AS given FROM reward_prize WHERE campaign_id = ?', [campaign.id])) as { stock: string; given: string }[];
      if (Number(counts.given) >= rewardReleased(Number(counts.stock), campaign.startsAt, campaign.endsAt, now)) return { prize: null };
      const [prize] = (await manager.query('SELECT id, kind, content, note FROM reward_prize WHERE campaign_id = ? AND draw_id IS NULL ORDER BY id LIMIT 1 FOR UPDATE', [campaign.id])) as { id: string; kind: string; content: string; note: string }[];
      if (prize === undefined) return { prize: null };
      const drawId = String(inserted.insertId);
      await manager.query('UPDATE reward_prize SET draw_id = ?, update_time = ? WHERE id = ?', [drawId, now, prize.id]);
      await manager.query('UPDATE reward_draw SET prize_id = ?, update_time = ? WHERE id = ?', [prize.id, now, drawId]);
      return { prize: { kind: prize.kind, content: prize.content, note: prize.note } };
    });
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
      await this.campaigns.delete({ id });
      removed++;
    }
    return removed;
  }
}
