import { Controller, Delete, HttpCode, Logger, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { DeviceRemovalService } from 'src/modules/pairing/device_removal.service';

@ApiTags('device')
@Controller('v1/devices')
@UseGuards(DeviceAuthGuard)
export class DeviceRemovalController {
  private readonly logger = new Logger('DeviceRemoval');

  constructor(private readonly removal: DeviceRemovalService) {}

  // 用户关闭私信：删除本设备在服务端的全部数据。
  @Delete()
  @HttpCode(204)
  async remove(@CurrentDevice() deviceId: string) {
    await this.removal.remove([deviceId]);
    this.logger.log(`[DeviceRemoval] action=remove deviceId=${deviceId}`);
  }
}
