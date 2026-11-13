import { createHash } from 'node:crypto';

// 灰度分桶（人工决策见客户端 lib/domain/rollout.dart）：sha256("SXD1-rollout\n" + 开关 + "\n" + 主体) 前 4 字节当无符号整数，乘 10000 除以 2^32 取整，得 0–9999；
// 放量 p% 时桶号小于 p×100 的在批次里。与客户端 rolloutBucket 逐位一致（共用 test/vectors/rollout_v1.json），以后要在服务端强制的功能（如按灰度开放的挑战）用它再算一遍。
export const rolloutBucket = (id: string, subject: string) => {
  const digest = createHash('sha256').update(`SXD1-rollout\n${id}\n${subject}`, 'utf8').digest();
  return Math.floor((digest.readUInt32BE(0) * 10000) / 0x100000000);
};

export const rolloutIncludes = (id: string, subject: string, percent: number) => rolloutBucket(id, subject) < percent * 100;
