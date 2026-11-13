import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 应用账号：对外只有随机的账号号（客户端拿它做灰度分桶），不带任何身份信息。
@Entity('app_account')
export class AppAccountEntity extends BaseEntity {
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'last_seen_time', type: 'datetime', precision: 3 }) lastSeenTime: Date;
}

// 账号的登录方式：provider 是登录方式名（现在只有 kingo），subject_hash 是带服务器密钥的 HMAC（学号不落库）。
@Entity('account_identity')
export class AccountIdentityEntity extends BaseEntity {
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'provider', type: 'varchar', length: 16 }) provider: string;
  @Column({ name: 'subject_hash', type: 'varchar', length: 64 }) subjectHash: string;
}

// 账号登录在哪把设备密钥上：一把密钥只属于一个账号；设备删除（退出账号、不活跃清理）时连带删除。
@Entity('account_device')
export class AccountDeviceEntity extends BaseEntity {
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'device_id', type: 'varchar', length: 32 }) deviceId: string;
}
