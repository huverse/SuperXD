import { randomBytes } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, opendir, rename, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import type { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { Inject, Injectable, OnModuleInit } from '@nestjs/common';
import Redis from 'ioredis';

import { env } from 'src/config/env';
import { DistributedLock, REDIS } from 'src/common/redis/redis.module';
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

// 已用量分两本账（11-28 审查 F06：原来预占记在已用量里，清理任务按目录重写时把还没写完的上传的预占冲掉，之后退回又把已用量减成少算甚至负数）：
// 已存好的包记在 diagnosticUsage，上传中的预占一笔一项记在 diagnosticReservations（到期时刻作分数，进程中途挂了也自己过期）。
// 11-28 复核 F06：已存好的那本账与目录一起变——存好（改名加记账）、删除、清理任务重算、Redis 丢了重建，都在同一把互斥锁里做（多实例共用），
// 原来存好的累加与清理的整笔重写没有协调，清理列完目录后才存好的包会被旧统计盖掉。持锁的只有这几步，收请求体不在锁里。
// 预占：先丢掉过期的预占，已存好的加上全部在途预占再加这个包不超过上限才记上，读与加在同一脚本里原子完成；已存好的那本账不在（Redis 丢了或过期）回 -1，
// 先按目录重建再预占。在途预占也算个数，所以最多 diagnosticStoreMaxFiles 项，脚本里逐项加的工作量有界。
const reserveScript = `if redis.call('EXISTS', KEYS[1]) == 0 then return -1 end
redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', ARGV[5])
local bytes = tonumber(redis.call('HGET', KEYS[1], 'bytes') or '0')
local files = tonumber(redis.call('HGET', KEYS[1], 'files') or '0')
for _, member in ipairs(redis.call('ZRANGE', KEYS[2], 0, -1)) do
  bytes = bytes + tonumber(string.match(member, ':(%d+)$'))
  files = files + 1
end
if bytes + tonumber(ARGV[1]) > tonumber(ARGV[2]) or files + 1 > tonumber(ARGV[3]) then return 0 end
redis.call('ZADD', KEYS[2], ARGV[6], ARGV[7])
redis.call('EXPIRE', KEYS[2], ARGV[4])
return 1`;
// 一笔预占最多留这么久（服务端收一个请求最多 5 分钟，留两倍）。
const reservationMs = 10 * 60 * 1000;
// 存好时记账：这笔预占还在（没过期、Redis 没丢）才把它换成已存好的用量；已存好的那本账不在回 -1（先重建再记），预占没了回 0（这次不收，
// 不然过期的上传也记进来，上限就守不住）。
const commitScript = `if redis.call('EXISTS', KEYS[1]) == 0 then return -1 end
if redis.call('ZREM', KEYS[2], ARGV[1]) == 0 then return 0 end
redis.call('HINCRBY', KEYS[1], 'bytes', ARGV[2])
redis.call('HINCRBY', KEYS[1], 'files', 1)
redis.call('EXPIRE', KEYS[1], ARGV[3])
return 1`;
// 删包后减账（账不在就不动，等重建）。
const dropScript = `if redis.call('EXISTS', KEYS[1]) == 0 then return 0 end
redis.call('HINCRBY', KEYS[1], 'bytes', -tonumber(ARGV[1]))
redis.call('HINCRBY', KEYS[1], 'files', -tonumber(ARGV[2]))
return 1`;
// 目录与已存好的账的互斥锁：持有最长 60 秒（清理逐个 stat 最多两千来个文件，远短于它），等锁最多 30 秒。
const storeLock = { name: 'diagnostic_store', ttlSeconds: 60, waitMs: 30_000 };

// 存好时那笔预占已经没了（上传超过租期、Redis 丢过）：这次不收，调用方请客户端重传。
export class DiagnosticReservationLost extends Error {
  constructor() {
    super('diagnostic reservation lost');
  }
}

// 诊断包的存放端口：密文按诊断编号存成文件，目录总量有上限。实现可换成对象存储。
export abstract class DiagnosticStore {
  // 按声明长度预占目录额度，回这笔预占的凭据；满了返回 null。
  abstract reserve(bytes: number): Promise<string | null>;
  // 写盘没成时退回这笔预占，与 reserve 对称。
  abstract release(reservation: string): Promise<void>;
  // 把请求体写成以诊断编号命名的文件，写好了把这笔预占换成已存好的用量；中途断开不留残片（预占由调用方 release）。
  // 这笔预占已经没了抛 DiagnosticReservationLost，不留文件。
  abstract save(id: string, body: Readable, reservation: string): Promise<void>;
  // 这个包的大小；没有（已到期删掉、编号不对）返回 null。
  abstract size(id: string): Promise<number | null>;
  // 删掉这些包（用户删除、注销账号）并从已存好的用量里减掉；没有的不算错。
  abstract remove(ids: string[]): Promise<void>;
  // 删掉到期的包与残片，按目录里存好的包重算已用量（不碰在途预占）；removed 是删掉的诊断编号（不含残片）。
  abstract sweep(now: number): Promise<{ removed: string[]; files: number; bytes: number }>;
}

// 本机目录实现：先写 <编号>.part 再改名，看到的 <编号> 一定是完整的；文件只给服务进程自己读写（600）。
// 已用量放 Redis（多实例共享、可丢）：上传时原子预占；存好、删除、清理重算与重建在互斥锁里与目录一起变，已存好的账因此与目录一致；Redis 丢了下一次预占先按目录重建。
@Injectable()
export class FileDiagnosticStore extends DiagnosticStore implements OnModuleInit {
  constructor(
    @Inject(REDIS) private readonly redis: Redis,
    private readonly lock: DistributedLock,
  ) {
    super();
  }

  private locked<T>(task: () => Promise<T>) {
    return this.lock.exclusive(storeLock.name, storeLock.ttlSeconds, storeLock.waitMs, task);
  }

  private get dir() {
    return env().diagnosticsDir;
  }

  async onModuleInit() {
    await mkdir(this.dir, { recursive: true });
  }

  async reserve(bytes: number): Promise<string | null> {
    const reservation = `${randomBytes(9).toString('base64url')}:${bytes}`;
    let accepted = await this.tryReserve(bytes, reservation);
    if (accepted === -1) {
      await this.locked(() => this.recount(Date.now(), false));
      accepted = await this.tryReserve(bytes, reservation);
    }
    return accepted === 1 ? reservation : null;
  }

  private async tryReserve(bytes: number, reservation: string) {
    const now = Date.now();
    return Number(await this.redis.eval(
      reserveScript,
      2,
      RedisKeys.diagnosticUsage(),
      RedisKeys.diagnosticReservations(),
      bytes,
      diagnosticStoreMaxBytes,
      diagnosticStoreMaxFiles,
      RedisKeyTTL.diagnosticUsage,
      now,
      now + reservationMs,
      reservation,
    ));
  }

  async release(reservation: string): Promise<void> {
    await this.redis.zrem(RedisKeys.diagnosticReservations(), reservation);
  }

  async save(id: string, body: Readable, reservation: string): Promise<void> {
    const part = join(this.dir, `${id}.part`), saved = join(this.dir, id);
    try {
      // 收请求体不在锁里（最长 5 分钟）。
      await pipeline(body, createWriteStream(part, { flags: 'wx', mode: 0o600 }));
      const { size } = await stat(part);
      await this.locked(async () => {
        let committed = await this.commit(reservation, size);
        if (committed === -1) {
          await this.recount(Date.now(), false);
          committed = await this.commit(reservation, size);
        }
        if (committed !== 1) throw new DiagnosticReservationLost();
        try {
          await rename(part, saved);
        } catch (error) {
          await this.redis.eval(dropScript, 1, RedisKeys.diagnosticUsage(), size, 1);
          throw error;
        }
      });
    } catch (error) {
      await rm(part, { force: true });
      throw error;
    }
  }

  private async commit(reservation: string, size: number) {
    return Number(await this.redis.eval(commitScript, 2, RedisKeys.diagnosticUsage(), RedisKeys.diagnosticReservations(), reservation, size, RedisKeyTTL.diagnosticUsage));
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
    if (names.length === 0) return;
    await this.locked(async () => {
      let bytes = 0, files = 0;
      for (let start = 0; start < names.length; start += 100) {
        const sizes = await Promise.all(
          names.slice(start, start + 100).map(async (name) => {
            const size = await this.size(name);
            if (size !== null) await rm(join(this.dir, name), { force: true });
            return size;
          }),
        );
        for (const size of sizes) {
          if (size === null) continue;
          bytes += size;
          files++;
        }
      }
      if (files > 0) await this.redis.eval(dropScript, 1, RedisKeys.diagnosticUsage(), bytes, files);
    });
  }

  sweep(now: number) {
    return this.locked(() => this.recount(now, true));
  }

  // 按目录重算已存好的用量（须在锁里）；prune 时顺带删到期的包与残片（清理任务），重建时只数。
  private async recount(now: number, prune: boolean) {
    const keepBefore = now - diagnosticKeepDays * 86400_000, partBefore = now - partStaleMs;
    const expired: string[] = [];
    let files = 0, bytes = 0;
    // 目录里最多 diagnosticStoreMaxFiles 个包（加上正在写的几个残片），逐个 stat 的工作量有界；不认识的文件不碰也不计。
    for await (const entry of await opendir(this.dir)) {
      const kept = diagnosticIdPattern.test(entry.name);
      if (!entry.isFile() || (!kept && !partPattern.test(entry.name))) continue;
      // 残片可能正被中途失败的上传删掉（那一步不在锁里），没了就跳过；存好的包只在锁里删，不会这样。
      const info = await stat(join(this.dir, entry.name)).catch((error: NodeJS.ErrnoException) => {
        if (!kept && error.code === 'ENOENT') return null;
        throw error;
      });
      if (info === null) continue;
      if (prune && info.mtimeMs < (kept ? keepBefore : partBefore)) {
        expired.push(entry.name);
        continue;
      }
      // 正在写的残片不算：它的额度在在途预占那本账里，存好时才转过来。
      if (!kept) continue;
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
