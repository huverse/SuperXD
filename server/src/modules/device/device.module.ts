import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { DeviceController } from 'src/modules/device/device.controller';
import { DeviceEntity } from 'src/modules/device/device.entity';
import { DeviceRepository, TypeormDeviceRepository } from 'src/modules/device/device.repository';
import { DeviceService } from 'src/modules/device/device.service';
import { DeviceAuthGuard } from 'src/modules/device/device_auth.guard';

@Module({
  imports: [TypeOrmModule.forFeature([DeviceEntity])],
  controllers: [DeviceController],
  providers: [{ provide: DeviceRepository, useClass: TypeormDeviceRepository }, DeviceService, DeviceAuthGuard],
  exports: [DeviceRepository, DeviceService, DeviceAuthGuard],
})
export class DeviceModule {}
