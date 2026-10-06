import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { ChaoxingPackController } from 'src/modules/chaoxing/chaoxing_pack.controller';
import { ChaoxingPackEntity } from 'src/modules/chaoxing/chaoxing_pack.entity';
import { ChaoxingPackRepository, TypeormChaoxingPackRepository } from 'src/modules/chaoxing/chaoxing_pack.repository';
import { ChaoxingPackService } from 'src/modules/chaoxing/chaoxing_pack.service';

@Module({
  imports: [TypeOrmModule.forFeature([ChaoxingPackEntity])],
  controllers: [ChaoxingPackController],
  providers: [{ provide: ChaoxingPackRepository, useClass: TypeormChaoxingPackRepository }, ChaoxingPackService],
  exports: [ChaoxingPackRepository, ChaoxingPackService],
})
export class ChaoxingPackModule {}
