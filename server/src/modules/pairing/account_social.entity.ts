import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 应用账号的私信设备（人工决策见客户端 lib/social/social_service.dart 文件头 11-14 的两条）：一个账号同一时刻只有一台，一台私信设备只属于一个账号。
// 接管时改指新设备；删设备（关闭私信、长期不活跃清理）与注销账号时删这一行。
@Entity('account_social')
export class AccountSocialEntity extends BaseEntity {
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'device_id', type: 'varchar', length: 32 }) deviceId: string;
}
