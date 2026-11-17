// 分批更新的健康回报与意见反馈（[人工决策-2026-11-16 17:05:21] 用户选定匿名健康回报加自动暂停、批次用户的匿名意见；规则与服务端判定见
// server/src/modules/app_health/app_health_rules.ts）：
// - 本机按校园日记「这天打开过、装着哪个版本、有没有致命错误」（致命 = 没接住的异常、框架报错、系统记下的崩溃与无响应）；前一天过完后发一份，
//   只有渠道、平台、版本号、那天与有没有致命错误，不带账号、设备号与错误内容；每天最多一份，只补最近 healthReportDays 天里没发过的。
// - 意见：装了这个版本 feedbackOpenDays 天内关于页给「新版本反馈」，好或不好、可加一句话（最多 feedbackTextMax 字），每个版本只收一次。
// - 联网按 NetworkService 的 appHealth、appFeedback（仅本机时都不发）。
const healthReportDays = 7;
const healthReportBatch = 3;
const feedbackOpenDays = 14;
const feedbackTextMax = 200;

class HealthDay {
  const HealthDay({required this.day, required this.versionCode, this.fatal = false, this.reported = false});
  // 校园日 YYYY-MM-DD。
  final String day;
  final int versionCode;
  final bool fatal;
  final bool reported;

  HealthDay copyWith({bool? fatal, bool? reported}) => HealthDay(day: day, versionCode: versionCode, fatal: fatal ?? this.fatal, reported: reported ?? this.reported);
}

// 本机记录：最近 healthReportDays 天每天一项；当前版本第一次打开的那天与意见交过没有（换版本从头记）。
class HealthRecord {
  const HealthRecord({this.days = const [], this.versionCode, this.versionSince, this.feedbackSent = false});
  final List<HealthDay> days;
  final int? versionCode;
  final String? versionSince;
  final bool feedbackSent;
}

String _shift(String day, int days) => DateTime.utc(int.parse(day.substring(0, 4)), int.parse(day.substring(5, 7)), int.parse(day.substring(8, 10))).add(Duration(days: days)).toIso8601String().substring(0, 10);

// 只留最近 healthReportDays 天（含今天）。
List<HealthDay> healthRecent(Iterable<HealthDay> days, String today) {
  final earliest = _shift(today, 1 - healthReportDays);
  return [for (final day in days) if (day.day.compareTo(earliest) >= 0 && day.day.compareTo(today) <= 0) day];
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
