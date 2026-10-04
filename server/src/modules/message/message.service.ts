import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { EntityManager } from 'typeorm';

import { RateLimiter } from 'src/common/redis/redis.module';
import { RelayCode, RelayError } from 'src/common/relay_error';
import { envelopeMaxBytes, fetchLimit, mailboxLimit, sendPerDay, sendPerMinute } from 'src/common/relay_limits';
import { decodeBase64url } from 'src/common/crypto/relay_crypto';
import { FriendService } from 'src/modules/friend/friend.service';
import { MailboxNotifier } from 'src/modules/message/mailbox_notifier';
import { MessageRepository } from 'src/modules/message/message.repository';

@Injectable()
export class MessageService {
  private readonly logger = new Logger('Message');

  constructor(
    private readonly messages: MessageRepository,
    private readonly friends: FriendService,
    private readonly limiter: RateLimiter,
    private readonly notifier: MailboxNotifier,
  ) {}

  decodeEnvelope(envelope: string) {
    const bytes = decodeBase64url(envelope);
    if (bytes === null || bytes.length === 0) throw new RelayError(RelayCode.invalidRequest, HttpStatus.BAD_REQUEST, '密文格式不正确');
    if (bytes.length > envelopeMaxBytes) throw new RelayError(RelayCode.envelopeTooLarge, HttpStatus.PAYLOAD_TOO_LARGE, '内容过大');
    return bytes;
  }

  async send(senderDeviceId: string, recipientDeviceId: string, clientId: string, envelope: string) {
    const bytes = this.decodeEnvelope(envelope);
    if (!(await this.friends.isFriend(senderDeviceId, recipientDeviceId))) throw new RelayError(RelayCode.notFriend, HttpStatus.FORBIDDEN, '对方不是好友');
    for (const [scope, limit, window] of [['send_minute', sendPerMinute, 60], ['send_day', sendPerDay, 86400]] as const) {
      const retryAfter = await this.limiter.hit(scope, senderDeviceId, limit, window);
      if (retryAfter !== null) throw new RelayError(RelayCode.rateLimited, HttpStatus.TOO_MANY_REQUESTS, '发送过于频繁', { retryAfter });
    }
    const stored = await this.deliver(recipientDeviceId, senderDeviceId, clientId, bytes);
    this.notifier.notify(recipientDeviceId);
    this.logger.debug(`[Message] action=send senderDeviceId=${senderDeviceId} recipientDeviceId=${recipientDeviceId} bytes=${bytes.length} id=${stored.id}`);
    return stored;
  }

  // 投递到对方信箱。待取条数与写入不在同一把锁里，并发时可能略超上限，上限只为防刷，不要求精确。
  async deliver(recipientDeviceId: string, senderDeviceId: string, clientId: string, envelope: Buffer, manager?: EntityManager) {
    if ((await this.messages.pending(recipientDeviceId, manager)) >= mailboxLimit) {
      throw new RelayError(RelayCode.mailboxFull, HttpStatus.CONFLICT, '对方待收消息已满');
    }
    return this.messages.insert(recipientDeviceId, senderDeviceId, clientId, envelope, manager);
  }

  // 长轮询：先登记等待再查库（查完之前到达的消息也能唤醒，不会漏），有消息立即返回；没有就挂起到被唤醒、超时或客户端断开，再查一次。
  async fetch(recipientDeviceId: string, afterId: string, limit: number, waitSeconds = 0, closed?: Promise<void>) {
    const waiter = waitSeconds > 0 ? this.notifier.wait(recipientDeviceId, waitSeconds * 1000) : null;
    try {
      const page = await this.page(recipientDeviceId, afterId, limit);
      if (waiter === null || page.messages.length > 0) return page;
      await Promise.race([waiter.signal, ...(closed ? [closed] : [])]);
      return this.page(recipientDeviceId, afterId, limit);
    } finally {
      waiter?.cancel();
    }
  }

  private async page(recipientDeviceId: string, afterId: string, limit: number) {
    const rows = await this.messages.fetch(recipientDeviceId, afterId, Math.min(limit, fetchLimit) + 1);
    const page = rows.slice(0, limit);
    return {
      messages: page.map((row) => ({ id: row.id, from: row.senderDeviceId, envelope: row.envelope.toString('base64url'), createTime: row.createTime.getTime() })),
      more: rows.length > limit,
    };
  }

  async ack(recipientDeviceId: string, ids: string[]) {
    const removed = await this.messages.ack(recipientDeviceId, ids);
    this.logger.debug(`[Message] action=ack recipientDeviceId=${recipientDeviceId} requested=${ids.length} removed=${removed}`);
    return removed;
  }
}
