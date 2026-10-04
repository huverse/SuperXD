import { Body, Controller, Get, HttpCode, Post, Query, UseGuards } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { fetchLimit } from 'src/common/relay_limits';
import { CurrentDevice, DeviceAuthGuard } from 'src/modules/device/device_auth.guard';
import { MessageService } from 'src/modules/message/message.service';
import * as dtos from 'src/modules/message/message.dto';

@ApiTags('message')
@Controller('v1/messages')
@UseGuards(DeviceAuthGuard)
export class MessageController {
  constructor(private readonly messages: MessageService) {}

  @Post()
  @HttpCode(200)
  async send(@CurrentDevice() deviceId: string, @Body() body: dtos.SendMessageDto): Promise<dtos.SendMessageResultDto> {
    const stored = await this.messages.send(deviceId, body.to, body.clientId, body.envelope);
    return { id: stored.id, createTime: stored.createTime.getTime() };
  }

  @Get()
  fetch(@CurrentDevice() deviceId: string, @Query() query: dtos.FetchMessagesQueryDto): Promise<dtos.InboxDto> {
    return this.messages.fetch(deviceId, query.after ?? '0', query.limit ?? fetchLimit);
  }

  @Post('ack')
  @HttpCode(200)
  async ack(@CurrentDevice() deviceId: string, @Body() body: dtos.AckMessagesDto): Promise<dtos.AckResultDto> {
    return { removed: await this.messages.ack(deviceId, body.ids) };
  }
}
