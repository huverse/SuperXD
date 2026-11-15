import { Column, Entity } from 'typeorm';

import { BaseEntity } from 'src/common/base.entity';

// 应用账号：对外只有随机的账号号（客户端拿它做灰度分桶）与用户名；密码与恢复码只存 scrypt 哈希（见 account_keys.ts），不存任何学校身份。
@Entity('app_account')
export class AppAccountEntity extends BaseEntity {
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'username', type: 'varchar', length: 20 }) username: string;
  @Column({ name: 'password_hash', type: 'varchar', length: 160 }) passwordHash: string;
  @Column({ name: 'recovery_hash', type: 'varchar', length: 160 }) recoveryHash: string;
  @Column({ name: 'last_seen_time', type: 'datetime', precision: 3 }) lastSeenTime: Date;
}

// 账号登录在哪把设备密钥上：一把密钥只属于一个账号；设备删除（退出账号、不活跃清理）时连带删除。
@Entity('account_device')
export class AccountDeviceEntity extends BaseEntity {
  @Column({ name: 'account_id', type: 'varchar', length: 32 }) accountId: string;
  @Column({ name: 'device_id', type: 'varchar', length: 32 }) deviceId: string;
}
