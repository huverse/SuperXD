import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, In, Repository } from 'typeorm';

import { friendLimit } from 'src/common/relay_limits';
import { FriendshipEntity } from 'src/modules/friend/friendship.entity';

export abstract class FriendshipRepository {
  abstract isFriend(ownerDeviceId: string, peerDeviceId: string): Promise<boolean>;
  abstract list(ownerDeviceId: string): Promise<FriendshipEntity[]>;
  abstract count(ownerDeviceId: string, manager: EntityManager): Promise<number>;
  // 建立双向关系，已存在时忽略；须在调用方事务内执行。
  abstract connect(first: string, second: string, manager: EntityManager): Promise<void>;
  // 删除双向关系；返回删掉的行数。
  abstract disconnect(first: string, second: string): Promise<number>;
  // 删除这些设备参与的全部关系（设备清理用），须在调用方事务内执行。
  abstract removeAllOf(deviceIds: string[], manager: EntityManager): Promise<void>;
}

@Injectable()
export class TypeormFriendshipRepository extends FriendshipRepository {
  constructor(@InjectRepository(FriendshipEntity) private readonly repository: Repository<FriendshipEntity>) {
    super();
  }

  isFriend(ownerDeviceId: string, peerDeviceId: string) {
    return this.repository.exists({ where: { ownerDeviceId, peerDeviceId } });
  }

  // 走 uk_owner_peer 前缀；好友数有上限 500，结果有界。
  list(ownerDeviceId: string) {
    return this.repository.find({ where: { ownerDeviceId }, order: { id: 'ASC' }, take: friendLimit });
  }

  count(ownerDeviceId: string, manager: EntityManager) {
    return manager.getRepository(FriendshipEntity).count({ where: { ownerDeviceId } });
  }

  async connect(first: string, second: string, manager: EntityManager) {
    const now = new Date();
    await manager.createQueryBuilder().insert().into(FriendshipEntity).orIgnore().values([
      { ownerDeviceId: first, peerDeviceId: second, createTime: now, updateTime: now },
      { ownerDeviceId: second, peerDeviceId: first, createTime: now, updateTime: now },
    ]).execute();
  }

  async disconnect(first: string, second: string) {
    const result = await this.repository.createQueryBuilder().delete()
      .where('(owner_device_id = :first AND peer_device_id = :second) OR (owner_device_id = :second AND peer_device_id = :first)', { first, second })
      .execute();
    return result.affected ?? 0;
  }

  async removeAllOf(deviceIds: string[], manager: EntityManager) {
    if (deviceIds.length === 0) return;
    const repository = manager.getRepository(FriendshipEntity);
    await repository.delete({ ownerDeviceId: In(deviceIds) });
    await repository.delete({ peerDeviceId: In(deviceIds) });
  }
}
