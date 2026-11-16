import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 灰度点名（人工决策见客户端 lib/domain/rollout.dart 的 11-16 那条）：开发者把某个开关单独开给某个应用账号，一个账号一个开关一行；
// expires_at 为空是一直开到撤销，到点的由清理任务删；随账号删除。名单只在服务器，不进公开的灰度配置。
@Entity('rollout_target')
export class RolloutTargetEntity extends BaseEntity {
  @Column({ name: 'flag_id', type: 'varchar', length: 64 }) flagId: string;
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'expires_at', type: 'datetime', precision: 3, nullable: true }) expiresAt: Date | null;
}
