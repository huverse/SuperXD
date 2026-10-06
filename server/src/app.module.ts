import { Module } from '@nestjs/common';
import { ScheduleModule } from '@nestjs/schedule';
import { TypeOrmModule } from '@nestjs/typeorm';

import { env } from 'src/config/env';
import { RedisModule } from 'src/common/redis/redis.module';
import { ChaoxingPackEntity } from 'src/modules/chaoxing/chaoxing_pack.entity';
import { ChaoxingPackModule } from 'src/modules/chaoxing/chaoxing_pack.module';
import { DeviceEntity } from 'src/modules/device/device.entity';
import { DeviceModule } from 'src/modules/device/device.module';
import { FriendshipEntity } from 'src/modules/friend/friendship.entity';
import { FriendModule } from 'src/modules/friend/friend.module';
import { HealthController } from 'src/modules/health/health.controller';
import { InviteModule } from 'src/modules/invite/invite.module';
import { MessageEntity } from 'src/modules/message/message.entity';
import { MessageModule } from 'src/modules/message/message.module';
import { PairingModule } from 'src/modules/pairing/pairing.module';

@Module({
  imports: [
    TypeOrmModule.forRootAsync({
      useFactory: () => ({
        type: 'mysql',
        ...env().mysql,
        entities: [DeviceEntity, FriendshipEntity, MessageEntity, ChaoxingPackEntity],
        // 表结构由人工执行 sql/schema.sql 管理，启动不做 DDL。
        synchronize: false,
        migrationsRun: false,
        timezone: 'Z',
        charset: 'utf8mb4_bin',
        // 连接与查询超时：数据库卡住时请求快速失败，不拖垮连接池。
        connectTimeout: 5000,
        extra: { connectionLimit: 20, waitForConnections: true, queueLimit: 200 },
        maxQueryExecutionTime: 1000,
        bigNumberStrings: true,
        supportBigNumbers: true,
      }),
    }),
    ScheduleModule.forRoot(),
    RedisModule,
    DeviceModule,
    InviteModule,
    FriendModule,
    MessageModule,
    ChaoxingPackModule,
    PairingModule,
  ],
  controllers: [HealthController],
})
export class AppModule {}
