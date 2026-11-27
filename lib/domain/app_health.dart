// 分批更新的健康回报与意见反馈（[人工决策-2026-11-16 17:05:21] 用户选定匿名健康回报加自动暂停、批次用户的匿名意见；规则与服务端判定见
// server/src/modules/app_health/app_health_rules.ts）：
// - 本机按校园日记「这天打开过、装着哪个版本、有没有致命错误」（致命 = 没接住的异常、框架报错、系统记下的崩溃与无响应）；前一天过完后发一份，
//   只有渠道、平台、版本号、那天与有没有致命错误，不带账号、设备号与错误内容；每天最多一份（11-27 起每个用过的版本一份，见下面那条），只补最近 healthReportDays 天里没发过的。
// - 意见：装了这个版本 feedbackOpenDays 天内关于页给「新版本反馈」，好或不好、可加一句话（最多 feedbackTextMax 字），每个版本只收一次。
// - 联网按 NetworkService 的 appHealth、appFeedback（仅本机时都不发）。
// [人工决策-2026-11-17 21:24:25] 补充上面第一条（用户选定，任务书第 6 项性能审查 P1-5）：健康回报多带两项性能档位，仍匿名、不带账号与设备号、仅本机时照旧不发，
// 只发档位（0 起的整数）、不发原始时长与帧数（原始数只在本机）：
//   启动档 launch：Dart 入口到首帧上屏的时长按 healthLaunchBounds 分四档（不到 0.5 秒、0.5–1 秒、1–2 秒、2 秒以上），一天里几次冷启动取中位那一档；
//   慢帧档 frames：这一天构建或栅格超出一帧预算（按屏幕刷新率）的帧占全部帧的比例按 healthSlowBounds 分四档（不到 5%、5–15%、15–40%、40% 以上），
//   不满 healthFrameMinimum 帧的那天不报这一项。服务端先只存与汇总（health_admin status 看各版本的分布），自动暂停仍只看致命错误。
//   参考 Android vitals 与 Firebase Performance 的冷启动与慢帧比例；没选：上报原始毫秒数与帧数、只在本机记、不加。
// [人工决策-2026-11-19 18:17:27] 档位界线照上面不改（用户让按业界最佳实践定）：Android vitals 把冷启动 5 秒以上算慢（量的是进程起到首屏，这里只量 Dart 入口到首帧，
// 所以最高档放在 2 秒更灵敏）、一半以上的帧超出绘制期限算渲染过慢（最高档 40% 与之接近，下面两档用来早看出变差）；同一指标的界线要稳定，
// 中途改了各版本的分布就没法互相比，真要改只在新开一组档位时改。少于 600 帧（60Hz 约 10 秒）的那天样本太少，照旧不报。
// [人工决策-2026-11-27 13:28:05] 改上面第一条的「每天最多一份」为每天每个用过的版本一份（用户选 A，没选「一天一份、换版本不带旧的致命」与「不改」）：
// 以前一天只有一项，换版本时当天已有的致命错误被带进新版本那一项，升级当天旧版本的崩溃算到新版本头上（11-27 查构建号 41 的致命时发现）；
// 现在按 校园日 + 版本 各一项，升级当天新旧版本各发一份、各带各的。同 Play vitals 与 Crashlytics 按出错的版本算，一台一天用过两个版本就两个版本各算一次。
// 这一版运行中出的错记到这个版本；上次退出原因（可能是升级前的旧版本）按系统记下的时刻认那天在用的版本（healthDayAt，靠本机记的 since）。
// 中转本来就按渠道、日、版本、平台各一行累加，服务端不用改；隐私政策第十一节与摘要第 1 条同步改写。
const healthReportDays = 7;
// 本机最多记的项数：最近 healthReportDays 天，平均每天两个版本；超了先丢最早的日子。
const healthEntryLimit = healthReportDays * 2;
const healthReportBatch = 3;
const feedbackOpenDays = 14;
const feedbackTextMax = 200;
const healthLaunchBounds = [Duration(milliseconds: 500), Duration(seconds: 1), Duration(seconds: 2)];
const healthSlowBounds = [.05, .15, .40];
const healthFrameMinimum = 600;

// 一次启动落在第几档（0 起）。
int healthLaunchTier(Duration elapsed) => healthLaunchBounds.where((bound) => elapsed >= bound).length;

// 一项是一个校园日里的一个版本（11-27 起同一天换过版本就有两项）。
class HealthDay {
  const HealthDay({required this.day, required this.versionCode, this.fatal = false, this.reported = false, this.launches = const [], this.frames = 0, this.slowFrames = 0, this.since});
  // 校园日 YYYY-MM-DD。
  final String day;
  final int versionCode;
  // 这个版本这天第一次记下的时刻（UTC，只在本机、不发出去）：给上次退出原因认是哪个版本；11-27 以前的记录没有，当这天开头。
  final DateTime? since;
  final bool fatal;
  final bool reported;
  // 这天各启动档的次数（下标是档位；没记过启动是空列表）。
  final List<int> launches;
  // 这天的帧数与其中的慢帧数（只在本机，发出去的是档位）。
  final int frames;
  final int slowFrames;

  // 这天冷启动的中位档；没记过启动为空。
  int? get launchTier {
    final total = launches.fold(0, (sum, count) => sum + count);
    if (total == 0) return null;
    var seen = 0;
    for (final (tier, count) in launches.indexed) {
      seen += count;
      if (seen * 2 >= total) return tier;
    }
    return launches.length - 1;
  }

  // 这天慢帧比例的档；帧数不满 healthFrameMinimum 为空。
  int? get frameTier => frames < healthFrameMinimum ? null : healthSlowBounds.where((bound) => slowFrames / frames >= bound).length;

  HealthDay copyWith({bool? fatal, bool? reported, List<int>? launches, int? frames, int? slowFrames}) => HealthDay(
    day: day,
    versionCode: versionCode,
    fatal: fatal ?? this.fatal,
    reported: reported ?? this.reported,
    launches: launches ?? this.launches,
    frames: frames ?? this.frames,
    slowFrames: slowFrames ?? this.slowFrames,
    since: since,
  );

  // 记一次启动。
  HealthDay withLaunch(Duration elapsed) {
    final tier = healthLaunchTier(elapsed);
    final counts = List<int>.filled(healthLaunchBounds.length + 1, 0);
    for (final (index, count) in launches.take(counts.length).indexed) {
      counts[index] = count;
    }
    counts[tier]++;
    return copyWith(launches: counts);
  }
}

// 本机记录：最近 healthReportDays 天每天每个用过的版本一项；当前版本第一次打开的那天与意见交过没有（换版本从头记）。
class HealthRecord {
  const HealthRecord({this.days = const [], this.versionCode, this.versionSince, this.feedbackSent = false});
  final List<HealthDay> days;
  final int? versionCode;
  final String? versionSince;
  final bool feedbackSent;
}

String _shift(String day, int days) => DateTime.utc(int.parse(day.substring(0, 4)), int.parse(day.substring(5, 7)), int.parse(day.substring(8, 10))).add(Duration(days: days)).toIso8601String().substring(0, 10);

// 只留最近 healthReportDays 天（含今天），最多 healthEntryLimit 项。
List<HealthDay> healthRecent(Iterable<HealthDay> days, String today) {
  final earliest = _shift(today, 1 - healthReportDays);
  final recent = [for (final day in days) if (day.day.compareTo(earliest) >= 0 && day.day.compareTo(today) <= 0) day];
  if (recent.length <= healthEntryLimit) return recent;
  recent.sort((left, right) => left.day.compareTo(right.day));
  return recent.sublist(recent.length - healthEntryLimit);
}

// 某一刻在用的是那天的哪一项：第一次记下的时刻不晚于它的最后一项；都晚于它（记下之前就出了错）取最早的一项；那天没有记录为空。
HealthDay? healthDayAt(Iterable<HealthDay> days, String day, DateTime at) {
  DateTime sinceOf(HealthDay item) => item.since ?? DateTime.utc(0);
  final candidates = [for (final item in days) if (item.day == day) item]..sort((left, right) => sinceOf(left).compareTo(sinceOf(right)));
  if (candidates.isEmpty) return null;
  return candidates.lastWhere((item) => !sinceOf(item).isAfter(at), orElse: () => candidates.first);
}

// 该发的：已经过完、没发过的，从新到旧最多 healthReportBatch 天。
List<HealthDay> healthDue(HealthRecord record, String today) =>
    (healthRecent(record.days, today).where((day) => !day.reported && day.day.compareTo(today) < 0).toList()..sort((left, right) => right.day.compareTo(left.day))).take(healthReportBatch).toList();

// 关于页给不给「新版本反馈」：当前版本装了不到 feedbackOpenDays 天、还没交过。
bool healthFeedbackOpen(HealthRecord record, int versionCode, String today) =>
    record.versionCode == versionCode && !record.feedbackSent && record.versionSince != null && today.compareTo(_shift(record.versionSince!, feedbackOpenDays)) < 0;

class AppHealthException implements Exception {
  const AppHealthException(this.message, {this.rejected = false});
  final String message;
  // 服务器认为内容不合（4xx）：健康回报记成发过、不再重发。
  final bool rejected;
  @override
  String toString() => message;
}

// 发给中转（device 实现）：都匿名、免签名。连不上、限流抛 AppHealthException。
abstract interface class AppHealthClient {
  Future<void> report({required String channel, required String platform, required HealthDay day});
  Future<void> feedback({required String channel, required String platform, required int versionCode, required bool good, required String text});
}

// 本机记录（local 实现）。
abstract class AppHealthMemory {
  HealthRecord get record;
  Future<void> save(HealthRecord record);
}
