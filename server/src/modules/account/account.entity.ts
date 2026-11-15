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

// 注销账号时它的每把设备密钥记一行墓碑（人工决策见 account.service.ts 的 remove）：这些密钥再来回 ACCOUNT_DELETED，客户端据此清掉本机那个账号的私信；
// 被顶掉、恢复码重设踢下线的密钥不记，照旧回 ACCOUNT_NOT_FOUND。保留 accountTombstoneDays 天，由账号的清理任务删。
@Entity('account_tombstone')
export class AccountTombstoneEntity extends BaseEntity {
  @Column({ name: 'device_id', type: 'varchar', length: 32 }) deviceId: string;
}
