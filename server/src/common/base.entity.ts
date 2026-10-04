import { Column, PrimaryGeneratedColumn } from 'typeorm';

// 统一实体基类：时间由代码显式写入（INSERT 设 createTime/updateTime，UPDATE 设 updateTime），一律 UTC。
export abstract class BaseEntity {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true }) id: string;
  @Column({ name: 'create_time', type: 'datetime', precision: 3 }) createTime: Date;
  @Column({ name: 'update_time', type: 'datetime', precision: 3 }) updateTime: Date;
}
