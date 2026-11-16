import { ApiProperty } from '@nestjs/swagger';

export class FlagTargetDto {
  @ApiProperty({ description: '开关编号（同灰度配置里的 id）' }) id: string;
  @ApiProperty({ description: '点到什么时刻（ISO 8601，UTC），为空是一直开到撤销', type: String, nullable: true }) until: string | null;
}

export class FlagTargetsDto {
  @ApiProperty({ description: '这个账号此刻被点名的开关', type: [FlagTargetDto] }) flags: FlagTargetDto[];
}
