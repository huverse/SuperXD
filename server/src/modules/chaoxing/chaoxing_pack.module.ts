import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { ChaoxingPackController } from 'src/modules/chaoxing/chaoxing_pack.controller';
import { ChaoxingPackEntity } from 'src/modules/chaoxing/chaoxing_pack.entity';
import { ChaoxingPackRepository, TypeormChaoxingPackRepository } from 'src/modules/chaoxing/chaoxing_pack.repository';
import { ChaoxingPackRetentionTask } from 'src/modules/chaoxing/chaoxing_pack_retention.task';
import { ChaoxingPackService } from 'src/modules/chaoxing/chaoxing_pack.service';

@Module({
  imports: [TypeOrmModule.forFeature([ChaoxingPackEntity])],
  controllers: [ChaoxingPackController],
  providers: [{ provide: ChaoxingPackRepository, useClass: TypeormChaoxingPackRepository }, ChaoxingPackService, ChaoxingPackRetentionTask],
})
export class ChaoxingPackModule {}
