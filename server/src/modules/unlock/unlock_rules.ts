import { rolloutIncludes } from 'src/common/rollout_bucket';
import { RolloutUnlockDto } from 'src/modules/app_release/app_release.dto';

// [人工决策-2026-11-14 20:20:18] 解锁（用户选「隐藏服务直接开」与「游乐场内容」，机制选「现在一起做好」；等级加权选「按等级自动加权」）：
// 一项解锁写在灰度配置 rollout.json 的 unlocks（流水线签名下发，改了不用发版），编号用约定前缀：game.<游戏 id> 是新游戏抢先玩，toolbox.<工具 id> 是隐藏的工具；
// 条件可写等级门槛 minLevel、价格 price、抽签比例 percent（按等级加权，同灰度）、公开时刻 publicAt，满足任一就开：
// - 公开时刻到了人人能用（含没登录的），解锁记录在公开 30 天后删，买过的不退（助手定的默认，开工时告诉了用户）；
// - 等级到了直接开、不花积分，降级就不再开（要一直用的花积分买）；
// - 花积分买的永久有效，与记解锁同一事务；抽签抽中的服务器记一条，以后降级也不踢出；
// - 标 retired 是下架：谁都不能用，买过的由清理任务退回积分（只认这个显式标记，配置读不了或漏写一项都不会误退）。
// 客户端在本机按同一规则显示（lib/application/unlocks.dart），服务端要强制的功能用 UnlockService.isOpen 再核一次。
export type UnlockReason = 'public' | 'level' | 'owned' | 'drawn';

export const unlockPublic = (unlock: RolloutUnlockDto, now: number) => unlock.publicAt !== undefined && Date.parse(unlock.publicAt) <= now;

// 这个账号此刻为什么能用（不能用为空）：先看下架与公开，再看等级、记过的解锁，最后按等级加权抽签。
export const unlockReason = (unlock: RolloutUnlockDto, accountId: string, level: number, owned: boolean, now: number): UnlockReason | null => {
  if (unlock.retired === true) return null;
  if (unlockPublic(unlock, now)) return 'public';
  if (unlock.minLevel !== undefined && level >= unlock.minLevel) return 'level';
  if (owned) return 'owned';
  if (unlock.percent !== undefined && rolloutIncludes(unlock.id, accountId, unlock.percent, level)) return 'drawn';
  return null;
};
