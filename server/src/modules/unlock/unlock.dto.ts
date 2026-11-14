import { ApiProperty } from '@nestjs/swagger';
import { Matches } from 'class-validator';

export class UnlockParamDto {
  @ApiProperty({ description: '解锁的编号，如 game.sudoku' }) @Matches(/^[a-z0-9][a-z0-9._-]{0,63}$/) id: string;
}

export class UnlockStateDto {
  @ApiProperty({ description: '这个账号此刻的积分等级 0–5' }) level: number;
  @ApiProperty({ description: '这个账号此刻能用的解锁编号（含已公开的）', type: [String] }) open: string[];
  @ApiProperty({ description: '服务器时间，毫秒' }) serverTime: number;
}
