import 'package:superxd/domain/app_account.dart';

// [人工决策-2026-10-23 23:25:34] 节日（用户要求）：到了某个节日，进应用时播一段精心设计的庆祝动画（同 Google Doodle：同一个节日每年都重画）。
// 不写死、不做预制全套：维护者点名哪个节日就做哪个，同一个节日的每一次都单独定制打磨；节日里可能随机发支付宝口令或二维码红包，
// 抽签只在服务器（概率模型见 server/src/modules/reward/reward_odds.ts），没抽中的人不打扰、只看节日动画；奖励的揭晓动画是预制的。
// 什么时候播走打扰时机（domain/interruption.dart、application/app_moments.dart）；动画登记在 page/festival/festival_catalog.dart。
//
// [人工决策-2026-11-10 12:55:52] 抽签改为用已登记的中转设备签名（取代 10-23 起本机随机参与号、免签名抽签；服务端见 server/src/modules/reward/reward_odds.ts）：
// 免签名时换个参与号就能再抽，一个脚本就能把每小时的放量额度拿完，奖品是真钱。用户选定（接受因此改隐私政策）：
// - 抽奖用单独的「抽奖身份」密钥对（FestivalPass，social 实现），不复用私信身份：隐私政策承诺过参与不关联教务账号、私信身份与设备标识，复用就连上了。
// - 按需登记、不给所有人登记：登记表里有带抽奖的节日、今天在它开始前 festivalPassLeadDays（7）天到结束之间、且已同意协议与政策时，打开应用才生成密钥并向中转登记一次；
//   提前 7 天是因为校园网 NAT 下节日当天大家同时登记会撞中转「每个出口每小时 20 台新设备」的注册限流。被限流或没连上就下次打开再试；
//   抽签时还没登记成功的照「没连上，下次回到前台补抽」处理。没有这样的节日时不生成密钥、不联网。
// - 节日都过了以后第一次打开应用时，请中转删除这台抽奖设备并删掉本机密钥；没删成的（没再打开、已卸载）由中转 400 天不活跃清理兜底。
// - 本机原来的随机参与号不再发出、不再记录（从没发出过：登记表一直是空的）。活跃天数仍由客户端自报，概率模型不变。
// 没选：所有人启动就登记（没有节日时也多一台设备与一次联网）、复用私信身份、只收紧按 IP 的限流（校园网 NAT 下误伤同学、挡不住换出口）。
// （抽奖身份这一套由下一条取代，删掉时它从没在任何手机上生成过：登记表一直是空的。）
//
// [人工决策-2026-11-14 16:47:34] 节日抽奖并入应用账号（第 4 阶段，用户选「只有登录了才能抽」，服务端见 reward_odds.ts）：抽签用当前应用账号
// 的设备密钥签名，一个人一次活动只抽一次（服务器按账号最早的登录身份认，换设备、重装、注销重建都不能重抽）；没登录应用账号的只看节日动画、
// 不抽签，动画放完提示可以去登录，登录后回到前台补抽。只认应用账号（AppAccountRef），不认教务：以后加别的登录方式不用改这里。
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

// 中转说这把密钥已不属于任何应用账号（别处注销、被清理）：这次不记结果，本机的应用账号随之核一次。
class FestivalNotSignedIn extends FestivalException {
  const FestivalNotSignedIn() : super('没有登录应用账号');
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

// 本机记录（local 实现，见 local/festival_memory.dart）：近 30 天打开过的校园日、播过的节日、抽过签的节日（结果已定，不再抽）、抽中的奖品。
// 播过与抽过各只留最近 festivalHistoryLimit 次，奖品按 festivalPrizeKeepDays 清。
const festivalHistoryLimit = 20;

class FestivalRecord {
  const FestivalRecord({this.activeDays = const {}, this.played = const [], this.drawn = const [], this.prizes = const []});
  final Set<String> activeDays;
  final List<String> played;
  final List<String> drawn;
  final List<FestivalPrize> prizes;
}

abstract class FestivalMemory {
  FestivalRecord get record;
  Future<void> save(FestivalRecord record);
}

// 抽签（social 实现：自建中转，用这个应用账号的设备密钥签名）。连不上、限流时抛 FestivalException，账号已不在抛 FestivalNotSignedIn；
// 同一个人重复抽返回同一个结果。
abstract class FestivalRewardClient {
  Future<FestivalDraw> draw(AppAccountRef account, String campaign, {required String occasion, required int activeDays});
}
