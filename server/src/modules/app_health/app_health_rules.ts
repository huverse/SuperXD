import { healthMinSamples, healthPauseMargin, healthPauseRatio } from 'src/common/relay_limits';

// [人工决策-2026-11-16 17:05:21] 分批更新加匿名健康回报与自动暂停、批次用户的匿名意见反馈（用户选定，任务书第 3 项：分批更新要能拿到部分用户的意见、
// 尽量减少更新的不良后果；参考 Google Play 分阶段发布按 Android vitals 暂停、Firebase「无崩溃用户比例」）：
// - 健康回报：每台每天最多一次（11-27 起每天每个用过的版本一次，人工决策见客户端 lib/domain/app_health.dart；这里照旧按版本累加，不用改），前一天结束后发「渠道、平台、版本号、那一天（校园日）、那天有没有致命错误」，不带账号、设备号或任何能认出人的东西；
//   致命 = 应用层没接住的异常、框架报错、系统记下的崩溃与无响应（客户端 lib/application/app_health.dart）。中转按渠道、平台、版本、日累加两个数（份数、致命份数），不存原始回报。
// - 自动暂停（下面 healthVerdict）：每小时比较最近几天里最新版与上一版的致命率，样本够且明显更高就记一条暂停；/v1/app/flags 的回复里不签名地带上暂停的版本，
//   客户端只拿它来少提示（自动检查不提示这一版，手动检查与必须更新照旧），被冒充最多让人晚点更新。维护者看过后用 health_admin resume 解除，解除后不再自动停这一版。
// - 意见：装了新版本 14 天内，关于页给「新版本反馈」：好或不好、可加一句话（最多 200 字），匿名；维护者用 health_admin feedback 看，不回复（产品方向：永不加人工客服）。
// - 本地化模式下都不发（客户端 NetworkService 的 appHealth、appFeedback）。没选：按设备去重（要设备号）、上传崩溃堆栈（已有诊断包，由用户确认后才传）。
// [人工决策-2026-11-17 21:24:25] 补充上一条（用户选定，任务书第 6 项性能审查 P1-5）：回报另带两项性能档位，仍匿名、只有档位（0 起的整数）、没有原始时长与帧数，
// 旧客户端不带、带不出的那天也不带（可选字段）：
// - launch 启动档：客户端 Dart 入口到首帧上屏的时长，0 不到 0.5 秒、1 为 0.5–1 秒、2 为 1–2 秒、3 为 2 秒以上（客户端 healthLaunchBounds），一天几次取中位档；
// - frames 慢帧档：这一天构建或栅格超出一帧预算的帧占比，0 不到 5%、1 为 5–15%、2 为 15–40%、3 为 40% 以上（客户端 healthSlowBounds），帧太少的那天不带。
// 中转按渠道、平台、版本、日把每档的份数累加进 app_health_daily 的 launch_t0–t3、frames_t0–t3，health_admin status 看各版本的分布；
// 先只存与汇总，下面的自动暂停仍只看致命率（够了样本、定好门槛后再说要不要按档位停）。
export const healthLaunchTiers = 4;
export const healthFrameTiers = 4;
export type HealthTiers = { launch?: number; frames?: number };
// 各档份数的列名（launch_t0…、frames_t0…），汇总表与维护命令共用。
export const tierColumns = (kind: 'launch' | 'frames', count: number) => Array.from({ length: count }, (_, tier) => `${kind}_t${tier}`);
export type HealthSample = { versionCode: number; reports: number; fatal: number };

// 新版（最高版本号）比上一版明显差就返回要暂停的版本号，否则为空。两版都要有至少 healthMinSamples 份。
export const healthVerdict = (samples: HealthSample[]): number | null => {
  const sorted = samples.filter((sample) => sample.reports > 0).sort((left, right) => right.versionCode - left.versionCode);
  const [latest, previous] = sorted;
  if (latest === undefined || previous === undefined || latest.reports < healthMinSamples || previous.reports < healthMinSamples) return null;
  const latestRate = latest.fatal / latest.reports, previousRate = previous.fatal / previous.reports;
  return latestRate > previousRate * healthPauseRatio && latestRate - previousRate >= healthPauseMargin ? latest.versionCode : null;
};

// 分批更新的开关名，同客户端 lib/domain/rollout.dart 的 appUpdateRolloutId。
export const appUpdateRolloutId = (channel: string, versionCode: number) => `app_update.${channel}.${versionCode}`;
