import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';

import { ChaoxingPackEntity } from 'src/modules/chaoxing/chaoxing_pack.entity';

export abstract class ChaoxingPackRepository {
  abstract insert(pickupId: string, data: Buffer, expireTime: Date): Promise<void>;
  // 取走即删：同一事务里锁定再删，两个请求同时取只会有一个人拿到；已过期的顺手删掉并返回空。
  abstract take(pickupId: string, now: Date): Promise<Buffer | null>;
  // 删除最多 limit 条已过期的包，返回删除条数。
  abstract deleteExpired(now: Date, limit: number): Promise<number>;
}

@Injectable()
export class TypeormChaoxingPackRepository extends ChaoxingPackRepository {
  constructor(@InjectRepository(ChaoxingPackEntity) private readonly repository: Repository<ChaoxingPackEntity>) {
    super();
  }

  async insert(pickupId: string, data: Buffer, expireTime: Date) {
    const now = new Date();
    await this.repository.insert({ pickupId, data, bytes: data.length, expireTime, createTime: now, updateTime: now });
  }

  async take(pickupId: string, now: Date) {
    return this.repository.manager.transaction(async (manager: EntityManager) => {
      const repository = manager.getRepository(ChaoxingPackEntity);
      const row = await repository
        .createQueryBuilder('pack')
        .setLock('pessimistic_write')
        .where('pack.pickup_id = :pickupId', { pickupId })
        .getOne();
      if (row === null) return null;
      await repository.delete({ id: row.id });
      // 过期判定在取件这一刻做，不等清理任务：过期时间之后的取件一律当不存在。
      return row.expireTime.getTime() > now.getTime() ? row.data : null;
    });
  }

  async deleteExpired(now: Date, limit: number) {
    const result = await this.repository.query('DELETE FROM chaoxing_pack WHERE expire_time < ? ORDER BY expire_time LIMIT ?', [now, limit]);
    return (result as { affectedRows: number }).affectedRows;
  }
}
