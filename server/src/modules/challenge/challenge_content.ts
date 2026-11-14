import { Injectable, Logger } from '@nestjs/common';
import { LRUCache } from 'lru-cache';
import { readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';

import { env } from 'src/config/env';
import { challengeBankCacheFiles, challengeBankFileMaxBytes, challengeConfigMaxBytes, challengeMaxLevels } from 'src/common/relay_limits';
import { periodOf } from 'src/modules/challenge/challenge_calendar';
import { ChallengeConfig, ChallengeConfigError, ChallengeTemplate, ChallengeTier, parseChallengeConfig } from 'src/modules/challenge/challenge_config';
import { judgedGames } from 'src/modules/challenge/judges/judges';

// 题库里的一道题（tool/challenge_bank.dart 用保密种子生成，第 2 版）：题面（Dart 规则编码）、预计用时（秒）、难度分、碎片（天平称球为空）、
// 要最少步数的游戏的最少步数、能写成 ? 的几处（补条件的游戏）与几个标号的出口（冰面滑行：每个当终点时的最少步数、碎片与预计用时）。
export type BankSlot = { at: number; value: number };
export type BankExit = { cell: number; minimum: number; fragment: number; expected: number; difficulty: number };
export type BankEntry = { id: string; puzzle: unknown; expected: number; difficulty: number; fragment: number | null; minimum: number | null; slots: BankSlot[]; exits: BankExit[] };

// 此刻开放的一个挑战；ticket 是开局要付的积分，0 是免费。
export type OpenChallenge = { id: string; title: string; template: ChallengeTemplate; start: number; end: number; ticket: number };

type Cached<T> = { mtimeMs: number; size: number; value: T };

// 挑战的内容（配置与题库）：都在发布目录的 challenge 下，按文件的修改时间与大小缓存，换文件即生效（热更新，人工决策见 challenge_config.ts）。
// 配置写坏了接着用上一份好的；题库每个文件读进内存（每档几十到一两百道），LRU 最多缓存 challengeBankCacheFiles 个。
@Injectable()
export class ChallengeContent {
  private readonly logger = new Logger('ChallengeContent');
  private config: Cached<ChallengeConfig> | undefined;
  private readonly banks = new LRUCache<string, Cached<BankEntry[]>>({ max: challengeBankCacheFiles });

  private get directory() {
    return join(env().releasesDir, 'challenge');
  }

  // 当前配置；还没放配置文件返回 null（挑战列表为空）。
  async currentConfig(): Promise<ChallengeConfig | null> {
    const path = join(this.directory, 'config.json');
    const info = await stat(path).catch(() => null);
    if (info === null) return this.config?.value ?? null;
    if (this.config !== undefined && this.config.mtimeMs === info.mtimeMs && this.config.size === info.size) return this.config.value;
    try {
      if (info.size > challengeConfigMaxBytes) throw new ChallengeConfigError(`配置文件超过 ${challengeConfigMaxBytes} 字节`);
      const value = parseChallengeConfig(JSON.parse(await readFile(path, 'utf8')), judgedGames, challengeMaxLevels);
      this.config = { mtimeMs: info.mtimeMs, size: info.size, value };
      this.logger.log(`[ChallengeContent] action=config_load templates=${value.templates.size} rotations=${value.rotations.length} events=${value.events.length}`);
    } catch (error) {
      console.error(error);
      this.logger.error(`[ChallengeContent] action=config_load errorType=${error instanceof Error ? error.constructor.name : typeof error} keepPrevious=${this.config !== undefined}`);
    }
    return this.config?.value ?? null;
  }

  // 此刻开放的全部挑战：每个轮换在本周期（按业务时区）各模板一个，加上正在进行的限时活动。
  async openChallenges(now: number): Promise<OpenChallenge[]> {
    const config = await this.currentConfig();
    if (config === null) return [];
    const timeZone = env().businessTimeZone;
    const open: OpenChallenge[] = [];
    for (const rotation of config.rotations) {
      const period = periodOf(now, rotation.every, timeZone);
      for (const name of rotation.templates) {
        const template = config.templates.get(name)!;
        open.push({ id: `${rotation.id}.${period.date}.${name}`, title: template.title, template, start: period.start, end: period.end, ticket: rotation.ticket });
      }
    }
    for (const event of config.events) {
      if (event.start <= now && now < event.end) open.push({ id: event.id, title: event.title, template: config.templates.get(event.template)!, start: event.start, end: event.end, ticket: event.ticket });
    }
    return open;
  }

  async openChallenge(id: string, now: number) {
    return (await this.openChallenges(now)).find((challenge) => challenge.id === id) ?? null;
  }

  // 一个游戏一档的题库；没有这个文件或写坏了返回空（出题时就不选这个游戏）。
  async bank(game: string, tier: ChallengeTier): Promise<BankEntry[]> {
    const path = join(this.directory, 'bank', `${game}.${tier}.json`);
    const info = await stat(path).catch(() => null);
    if (info === null) return [];
    const cached = this.banks.get(path);
    if (cached !== undefined && cached.mtimeMs === info.mtimeMs && cached.size === info.size) return cached.value;
    try {
      if (info.size > challengeBankFileMaxBytes) throw new ChallengeConfigError(`题库文件超过 ${challengeBankFileMaxBytes} 字节`);
      const value = parseBank(JSON.parse(await readFile(path, 'utf8')));
      this.banks.set(path, { mtimeMs: info.mtimeMs, size: info.size, value });
      return value;
    } catch (error) {
      console.error(error);
      this.logger.error(`[ChallengeContent] action=bank_load game=${game} tier=${tier} errorType=${error instanceof Error ? error.constructor.name : typeof error}`);
      return cached?.value ?? [];
    }
  }
}

const whole = (value: unknown, min: number, max: number) => Number.isInteger(value) && (value as number) >= min && (value as number) <= max;

const parseBank = (raw: unknown): BankEntry[] => {
  const file = raw as { version?: unknown; entries?: unknown };
  if (file?.version !== 2 || !Array.isArray(file.entries)) throw new ChallengeConfigError('题库格式不对');
  return file.entries.map((item: unknown) => {
    const entry = item as Partial<BankEntry>;
    const slots = Array.isArray(entry.slots) ? entry.slots : [];
    const exits = Array.isArray(entry.exits) ? entry.exits : [];
    if (typeof entry.id !== 'string' || entry.puzzle === undefined || !whole(entry.expected, 1, 86400) || !whole(entry.difficulty, 1, 10)) throw new ChallengeConfigError('题库条目不对');
    if ((entry.fragment !== null && !whole(entry.fragment, 0, 99999)) || (entry.minimum !== null && !whole(entry.minimum, 0, 99999))) throw new ChallengeConfigError('题库的碎片或最少步数不对');
    for (const slot of slots) if (!whole(slot?.at, 0, 999) || !whole(slot?.value, 0, 99)) throw new ChallengeConfigError('题库能写成 ? 的位置不对');
    for (const exit of exits) {
      if (![exit?.cell, exit?.minimum, exit?.fragment].every((value) => whole(value, 0, 99999)) || !whole(exit?.expected, 1, 86400) || !whole(exit?.difficulty, 1, 10)) throw new ChallengeConfigError('题库的出口不对');
    }
    return { id: entry.id, puzzle: entry.puzzle, expected: entry.expected!, difficulty: entry.difficulty!, fragment: entry.fragment ?? null, minimum: entry.minimum ?? null, slots, exits };
  });
};
