import { Module } from '@nestjs/common';

import { AccountModule } from 'src/modules/account/account.module';
import { ChallengeModule } from 'src/modules/challenge/challenge.module';
import { DeviceModule } from 'src/modules/device/device.module';
import { LeisureController } from 'src/modules/leisure/leisure.controller';
import { LeisureService } from 'src/modules/leisure/leisure.service';
import { PointsModule } from 'src/modules/points/points.module';
import { PassModule } from 'src/modules/pass/pass.module';
import { UnlockModule } from 'src/modules/unlock/unlock.module';

// 游乐场与积分（挑战、解锁、积分三个模块之上的一层）：只做跨模块的「删除数据」，依赖只自上而下。
@Module({
  imports: [DeviceModule, AccountModule, ChallengeModule, UnlockModule, PassModule, PointsModule],
  controllers: [LeisureController],
  providers: [LeisureService],
})
export class LeisureModule {}
