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
  // 私信换设备：from 的全部关系改挂到 to，对方那一行记下 from（已记着更早的旧号时保留更早的，对方客户端认得的是那个；正好等于 to 时清空）；
  // 两边本来就有的关系不重复，from 与 to 互为好友的那两行删掉。须在调用方事务内执行，行数以好友上限为界。
  abstract moveDevice(from: string, to: string, manager: EntityManager): Promise<void>;
  // owner 处理完这些好友换设备的提示：清掉 moved_from。
  abstract ackMoves(ownerDeviceId: string, peerDeviceIds: string[]): Promise<void>;
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

  // UPDATE IGNORE 跳过会撞 uk_owner_peer 的行（两边本来就有的关系），剩下的旧行随后删掉；owner 一侧走 uk_owner_peer 前缀，peer 一侧走 idx_peer。
  async moveDevice(from: string, to: string, manager: EntityManager) {
    const now = new Date();
    await manager.query('UPDATE IGNORE friendship SET owner_device_id = ?, update_time = ? WHERE owner_device_id = ?', [to, now, from]);
    await manager.query('DELETE FROM friendship WHERE owner_device_id = ?', [from]);
    // 记下的旧号正好是这次的新号（换走又拿回、对方还没处理）：对方认得的就是它，清空不再提示。
    await manager.query('UPDATE IGNORE friendship SET peer_device_id = ?, moved_from = NULLIF(COALESCE(moved_from, ?), ?), update_time = ? WHERE peer_device_id = ?', [to, from, to, now, from]);
    await manager.query('DELETE FROM friendship WHERE peer_device_id = ?', [from]);
    await manager.query('DELETE FROM friendship WHERE owner_device_id = ? AND peer_device_id = ?', [to, to]);
  }

  async ackMoves(ownerDeviceId: string, peerDeviceIds: string[]) {
    if (peerDeviceIds.length > 0) await this.repository.update({ ownerDeviceId, peerDeviceId: In(peerDeviceIds) }, { movedFrom: null, updateTime: new Date() });
  }
}
