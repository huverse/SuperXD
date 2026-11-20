import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { CinemaCatalogController } from 'src/modules/cinema_catalog/cinema_catalog.controller';
import { CinemaCatalogEntity, CinemaCatalogStateEntity } from 'src/modules/cinema_catalog/cinema_catalog.entity';
import { CinemaCatalogRepository, TypeormCinemaCatalogRepository } from 'src/modules/cinema_catalog/cinema_catalog.repository';
import { CinemaCatalogService } from 'src/modules/cinema_catalog/cinema_catalog.service';
import { CinemaCatalogSource } from 'src/modules/cinema_catalog/cinema_catalog_source';
import { CinemaCatalogTask } from 'src/modules/cinema_catalog/cinema_catalog.task';

// 电影院片名目录型源的服务端索引（规则见 cinema_catalog.service.ts）：配置读发布目录的 cinema.json，不碰账号。
@Module({
  imports: [TypeOrmModule.forFeature([CinemaCatalogEntity, CinemaCatalogStateEntity])],
  controllers: [CinemaCatalogController],
  providers: [{ provide: CinemaCatalogRepository, useClass: TypeormCinemaCatalogRepository }, CinemaCatalogService, CinemaCatalogSource, CinemaCatalogTask],
  exports: [CinemaCatalogService],
})
export class CinemaCatalogModule {}
