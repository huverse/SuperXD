import { Module } from '@nestjs/common';

import { AppReleaseController } from 'src/modules/app_release/app_release.controller';
import { AppReleaseService } from 'src/modules/app_release/app_release.service';

@Module({
  controllers: [AppReleaseController],
  providers: [AppReleaseService],
})
export class AppReleaseModule {}
