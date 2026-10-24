// [人工决策-2026-10-23 23:25:34] 节日（用户要求）：到了某个节日，进应用时播一段精心设计的庆祝动画（同 Google Doodle：同一个节日每年都重画）。
// 不写死、不做预制全套：维护者点名哪个节日就做哪个，同一个节日的每一次都单独定制打磨；节日里可能随机发支付宝口令或二维码红包，
// 抽签只在服务器（概率模型见 server/src/modules/reward/reward_odds.ts），没抽中的人不打扰、只看节日动画；奖励的揭晓动画是预制的。
// 什么时候播走打扰时机（domain/interruption.dart、application/app_moments.dart）；动画登记在 page/festival/festival_catalog.dart。
//
// 一次节日：编号（如 spring-2027，同一节日每一年是不同的一次；发出后不改，播过、抽过都按它记）、名字、校园时区的起止日期（含两端，YYYY-MM-DD）、
// 抽奖活动编号（为空不抽奖；与服务器上 reward_admin create 的编号一致）。
class FestivalOccasion {
  const FestivalOccasion({required this.id, required this.name, required this.from, required this.to, this.campaign});
  final String id;
  final String name;
  final String from;
  final String to;
  final String? campaign;

  // 校园日 today（YYYY-MM-DD）在这次节日里：日期字符串按字典序比较就是按日期比较。
  bool on(String today) => from.compareTo(today) <= 0 && today.compareTo(to) <= 0;
}

enum FestivalPrizeKind { password, qrCode }

// 抽中的奖品：支付宝口令原文或二维码内容，附言可为空。revealed 为揭晓过（拆过红包）。
class FestivalPrize {
  const FestivalPrize({required this.occasion, required this.kind, required this.content, required this.note, required this.wonAt, this.revealed = false});
  final String occasion;
  final FestivalPrizeKind kind;
  final String content;
  final String note;
  final DateTime wonAt;
  final bool revealed;

  FestivalPrize reveal() => FestivalPrize(occasion: occasion, kind: kind, content: content, note: note, wonAt: wonAt, revealed: true);
}

// 一次抽签的结果：抽中、没抽中、活动不在进行（没建、还没开始或已结束）。
sealed class FestivalDraw {
  const FestivalDraw();
}

class FestivalWon extends FestivalDraw {
  const FestivalWon(this.prize);
  final FestivalPrize prize;
}

class FestivalMissed extends FestivalDraw {
  const FestivalMissed();
}

class FestivalClosed extends FestivalDraw {
  const FestivalClosed();
}

class FestivalException implements Exception {
  const FestivalException(this.message);
  final String message;
  @override
  String toString() => message;
}

// 活跃度：近 30 天（含今天）里打开过应用的校园日数，抽奖时报给服务器做加权。本机只留这 30 天的日期，记录大小有上限。
const festivalActiveWindow = 30;

String _shift(String date, int days) {
  final shifted = DateTime.utc(int.parse(date.substring(0, 4)), int.parse(date.substring(5, 7)), int.parse(date.substring(8, 10))).add(Duration(days: days));
  return '${shifted.year}-${shifted.month.toString().padLeft(2, '0')}-${shifted.day.toString().padLeft(2, '0')}';
}

Set<String> festivalActiveDays(Iterable<String> days, String today) {
  final earliest = _shift(today, 1 - festivalActiveWindow);
  return {for (final day in days) if (day.compareTo(earliest) >= 0 && day.compareTo(today) <= 0) day};
}

// 抽中的奖品在节日结束后再留这么多天（可在「我的」里再打开），之后从本机删掉。
const festivalPrizeKeepDays = 3;

bool festivalPrizeKept(FestivalPrize prize, Iterable<FestivalOccasion> occasions, String today) {
  final occasion = occasions.where((item) => item.id == prize.occasion).firstOrNull;
  return occasion != null && today.compareTo(_shift(occasion.to, festivalPrizeKeepDays)) <= 0;
}

// 本机记录（local 实现，见 local/festival_memory.dart）：参与号（第一次抽签时生成的随机数，不关联任何账号）、近 30 天打开过的校园日、
// 播过的节日、抽过签的节日（结果已定，不再抽）、抽中的奖品。播过与抽过各只留最近 festivalHistoryLimit 次，奖品按 festivalPrizeKeepDays 清。
const festivalHistoryLimit = 20;

class FestivalRecord {
  const FestivalRecord({this.participant, this.activeDays = const {}, this.played = const [], this.drawn = const [], this.prizes = const []});
  final String? participant;
  final Set<String> activeDays;
  final List<String> played;
  final List<String> drawn;
  final List<FestivalPrize> prizes;
}

abstract class FestivalMemory {
  FestivalRecord get record;
  Future<void> save(FestivalRecord record);
}

// 抽签（device 实现：自建中转）。连不上、限流时抛 FestivalException；同一参与号重复抽返回同一个结果。
abstract class FestivalRewardClient {
  Future<FestivalDraw> draw(String campaign, {required String occasion, required String participant, required int activeDays});
}
