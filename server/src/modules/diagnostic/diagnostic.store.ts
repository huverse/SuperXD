import { randomBytes } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, opendir, rename, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import type { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { Inject, Injectable, OnModuleInit } from '@nestjs/common';
import Redis from 'ioredis';

import { env } from 'src/config/env';
import { REDIS } from 'src/common/redis/redis.module';
import { RedisKeys, RedisKeyTTL } from 'src/common/redis/redis_keys';
import { diagnosticKeepDays, diagnosticStoreMaxBytes, diagnosticStoreMaxFiles } from 'src/common/relay_limits';

// 诊断编号：5 字节随机数正好 40 位，写成 8 位 Crockford base32（去掉了 I、L、O、U，念给人听、手抄都不易错），同客户端 lib/device/relay_diagnostic_upload.dart。
const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
export const diagnosticIdPattern = /^[0-9A-HJKMNP-TV-Z]{8}$/;
const partPattern = /^[0-9A-HJKMNP-TV-Z]{8}\.part$/;
// 正在写的残片超过这么久就是中途断掉没清的（服务端收一个请求最多 5 分钟）。
const partStaleMs = 60 * 60 * 1000;

export const newDiagnosticId = (): string => {
  const value = randomBytes(5).readUIntBE(0, 5);
  return Array.from({ length: 8 }, (_, index) => alphabet[Math.floor(value / 32 ** (7 - index)) % 32]).join('');
};

// 预占额度：已用量加上这个包不超过上限才记上，读与加在同一脚本里原子完成（多实例共用一个目录）。
const reserveScript = `local bytes = tonumber(redis.call('HGET', KEYS[1], 'bytes') or '0')
local files = tonumber(redis.call('HGET', KEYS[1], 'files') or '0')
if bytes + tonumber(ARGV[1]) > tonumber(ARGV[2]) or files + 1 > tonumber(ARGV[3]) then return 0 end
redis.call('HINCRBY', KEYS[1], 'bytes', ARGV[1])
redis.call('HINCRBY', KEYS[1], 'files', 1)
redis.call('EXPIRE', KEYS[1], ARGV[4])
return 1`;

// 诊断包的存放端口：密文按诊断编号存成文件，目录总量有上限。实现可换成对象存储。
export abstract class DiagnosticStore {
  // 按声明长度预占目录额度，满了返回 false。
  abstract reserve(bytes: number): Promise<boolean>;
  // 写盘没成时退回预占，与 reserve 对称。
  abstract release(bytes: number): Promise<void>;
  // 把请求体写成以诊断编号命名的文件；中途断开不留残片。
  abstract save(id: string, body: Readable): Promise<void>;
  // 这个包的大小；没有（已到期删掉、编号不对）返回 null。
  abstract size(id: string): Promise<number | null>;
  // 删掉这些包（用户删除、注销账号）；没有的不算错，已用量等清理任务按目录重写。
  abstract remove(ids: string[]): Promise<void>;
  // 删掉到期的包与残片，按目录实际重写已用量；removed 是删掉的诊断编号（不含残片）。
  abstract sweep(now: number): Promise<{ removed: string[]; files: number; bytes: number }>;
}

// 本机目录实现：先写 <编号>.part 再改名，看到的 <编号> 一定是完整的；文件只给服务进程自己读写（600）。
// 已用量放 Redis（多实例共享、可丢）：上传时原子预占，清理任务每轮按目录实际重写，Redis 丢了也由它重建。
@Injectable()
export class FileDiagnosticStore extends DiagnosticStore implements OnModuleInit {
  constructor(@Inject(REDIS) private readonly redis: Redis) {
    super();
  }

  private get dir() {
    return env().diagnosticsDir;
  }

  async onModuleInit() {
    await mkdir(this.dir, { recursive: true });
  }

  async reserve(bytes: number): Promise<boolean> {
    const accepted = await this.redis.eval(reserveScript, 1, RedisKeys.diagnosticUsage(), bytes, diagnosticStoreMaxBytes, diagnosticStoreMaxFiles, RedisKeyTTL.diagnosticUsage);
    return Number(accepted) === 1;
  }

  async release(bytes: number): Promise<void> {
    await this.exec(this.redis.multi().hincrby(RedisKeys.diagnosticUsage(), 'bytes', -bytes).hincrby(RedisKeys.diagnosticUsage(), 'files', -1));
  }

  async save(id: string, body: Readable): Promise<void> {
    const part = join(this.dir, `${id}.part`);
    try {
      await pipeline(body, createWriteStream(part, { flags: 'wx', mode: 0o600 }));
      await rename(part, join(this.dir, id));
    } catch (error) {
      await rm(part, { force: true });
      throw error;
    }
  }

  async size(id: string) {
    if (!diagnosticIdPattern.test(id)) return null;
    try {
      return (await stat(join(this.dir, id))).size;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null;
      throw error;
    }
  }

  async remove(ids: string[]) {
    const names = ids.filter((id) => diagnosticIdPattern.test(id));
    for (let start = 0; start < names.length; start += 100) {
      await Promise.all(names.slice(start, start + 100).map((name) => rm(join(this.dir, name), { force: true })));
    }
  }

  async sweep(now: number) {
    const keepBefore = now - diagnosticKeepDays * 86400_000, partBefore = now - partStaleMs;
    const expired: string[] = [];
    let files = 0, bytes = 0;
    // 目录里最多 diagnosticStoreMaxFiles 个包（加上正在写的几个残片），逐个 stat 的工作量有界；不认识的文件不碰也不计。
    for await (const entry of await opendir(this.dir)) {
      const kept = diagnosticIdPattern.test(entry.name);
      if (!entry.isFile() || (!kept && !partPattern.test(entry.name))) continue;
      const info = await stat(join(this.dir, entry.name));
      if (info.mtimeMs < (kept ? keepBefore : partBefore)) {
        expired.push(entry.name);
        continue;
      }
      // 正在写的残片也算进去：它的额度已经预占过，这里按目录重写时不能把它漏掉。
      files++;
      bytes += info.size;
    }
    for (let start = 0; start < expired.length; start += 100) {
      await Promise.all(expired.slice(start, start + 100).map((name) => rm(join(this.dir, name), { force: true })));
    }
    await this.exec(this.redis.multi().hset(RedisKeys.diagnosticUsage(), { bytes, files }).expire(RedisKeys.diagnosticUsage(), RedisKeyTTL.diagnosticUsage));
    return { removed: expired.filter((name) => diagnosticIdPattern.test(name)), files, bytes };
  }

  // MULTI 里的命令出错不会让 exec 抛，逐项检查。
  private async exec(transaction: ReturnType<Redis['multi']>) {
    for (const [error] of (await transaction.exec()) ?? []) {
      if (error) throw error;
    }
  }
}
