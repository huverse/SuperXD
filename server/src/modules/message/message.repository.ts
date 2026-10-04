import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, In, MoreThan, Repository } from 'typeorm';

import { mailboxLimit, messageTtlDays } from 'src/common/relay_limits';
import { MessageEntity } from 'src/modules/message/message.entity';

export type StoredMessage = { id: string; createTime: Date };

export abstract class MessageRepository {
  // 待取条数，最多数到 mailboxLimit + 1 即停，扫描量有界。
  abstract pending(recipientDeviceId: string, manager?: EntityManager): Promise<number>;
  // 按 (发送方, 消息号) 幂等写入；重复发送返回已有的那条。
  abstract insert(recipientDeviceId: string, senderDeviceId: string, clientId: string, envelope: Buffer, manager?: EntityManager): Promise<StoredMessage>;
  abstract fetch(recipientDeviceId: string, afterId: string, limit: number): Promise<MessageEntity[]>;
  abstract ack(recipientDeviceId: string, ids: string[]): Promise<number>;
  // 删除最多 limit 条已过期消息，返回删除条数。
  abstract deleteExpired(now: Date, limit: number): Promise<number>;
  abstract removeMailboxes(deviceIds: string[], manager: EntityManager): Promise<void>;
}

@Injectable()
export class TypeormMessageRepository extends MessageRepository {
  constructor(@InjectRepository(MessageEntity) private readonly repository: Repository<MessageEntity>) {
    super();
  }

  async pending(recipientDeviceId: string, manager?: EntityManager) {
    const rows: { total: string | number }[] = await (manager ?? this.repository.manager).query(
      'SELECT COUNT(*) AS total FROM (SELECT 1 FROM message WHERE recipient_device_id = ? LIMIT ?) AS bounded',
      [recipientDeviceId, mailboxLimit + 1],
    );
    return Number(rows[0].total);
  }

  async insert(recipientDeviceId: string, senderDeviceId: string, clientId: string, envelope: Buffer, manager?: EntityManager) {
    const repository = (manager ?? this.repository.manager).getRepository(MessageEntity);
    const now = new Date();
    const expireTime = new Date(now.getTime() + messageTtlDays * 24 * 3600 * 1000);
    await repository.createQueryBuilder().insert().into(MessageEntity).orIgnore()
      .values({ recipientDeviceId, senderDeviceId, clientId, envelope, expireTime, createTime: now, updateTime: now })
      .execute();
    const stored = await repository.findOneOrFail({ select: { id: true, createTime: true }, where: { senderDeviceId, clientId } });
    return { id: stored.id, createTime: stored.createTime };
  }

  // 走 idx_recipient (recipient_device_id, id)，按 id 游标顺序取。
  fetch(recipientDeviceId: string, afterId: string, limit: number) {
    return this.repository.find({ where: { recipientDeviceId, id: MoreThan(afterId) }, order: { id: 'ASC' }, take: limit });
  }

  async ack(recipientDeviceId: string, ids: string[]) {
    if (ids.length === 0) return 0;
    const result = await this.repository.delete({ recipientDeviceId, id: In(ids) });
    return result.affected ?? 0;
  }

  async deleteExpired(now: Date, limit: number) {
    const result = await this.repository.query('DELETE FROM message WHERE expire_time < ? ORDER BY expire_time LIMIT ?', [now, limit]);
    return (result as { affectedRows: number }).affectedRows;
  }

  async removeMailboxes(deviceIds: string[], manager: EntityManager) {
    if (deviceIds.length > 0) await manager.getRepository(MessageEntity).delete({ recipientDeviceId: In(deviceIds) });
  }
}
