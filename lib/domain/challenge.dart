import 'package:superxd/domain/app_account.dart';

// 挑战与积分（人工决策见 lib/playground/challenge/challenge_rules.dart 与服务端 src/modules/points/points.service.ts）：
// 服务器下发挑战、出题、逐关核对、计时（不暂停）与结算，积分属于应用账号。这里是两边共用的类型与端口，协议见 server/README.md「挑战与积分」。
// 关与关之间是碎片与门：过关给一次碎片，收碎片的关先开门，全部过了输终章的最终密码才算全部过关。

// locked：给它碎片的关还没全过；gated：碎片齐了、门还没开。
enum ChallengeLevelState { locked, gated, open, solved, failed }

// 终章：locked 还有关没过（含加试题）、ready 能输最终密码、cleared 输对了。
enum ChallengeFinal { locked, ready, cleared }

class ChallengeSummary {
  const ChallengeSummary({
    required this.id,
    required this.title,
    required this.label,
    required this.levels,
    required this.tiers,
    required this.edges,
    required this.timeLimit,
    required this.endsAt,
    required this.best,
    required this.playable,
    required this.ticket,
  });
  final String id, title, label;
  final int levels;
  // 关卡图（首页画结构缩略图）：每一关的档位名与边（给碎片的关、收碎片的关在 tiers 里的下标）。
  final List<String> tiers;
  final List<(int, int)> edges;
  final Duration timeLimit;
  final DateTime endsAt;
  // 这个应用账号在这个挑战上的最好成绩，没玩过为空。
  final int? best;
  // 里面有这个版本没有的游戏时为假（要更新应用）。
  final bool playable;
  // 开局要付的积分门票，0 是免费；开局即扣、过没过都不退（[人工决策-2026-11-14 20:20:18] 见服务端 points.service.ts）。
  final int ticket;
}

class ChallengeCatalog {
  const ChallengeCatalog({required this.serverTime, required this.activeRun, required this.challenges});
  final DateTime serverTime;
  final String? activeRun;
  final List<ChallengeSummary> challenges;
}

// 门：门上的数 = 给它碎片的几关的碎片相加（sum）或相乘（product），只有一关就是那个碎片；开了以后 value 是门上的数。
class ChallengeGate {
  const ChallengeGate({required this.product, required this.value});
  final bool product;
  final int? value;
}

// 门上的数改写这一关的那一处：值 = 门上的数 ÷ modulus 的余数 + offset。slot 为真是补条件（题面里那一处写成 ?，at 是位置：
// 24 点第几张牌、八皇后第几行、数回第几格、密码破译第几行的「位置也对」、骑士与无赖第几个人那句话的人数），为假是改目标（汉诺塔的目标柱、冰面滑行的出口、记忆闪光镜像）。
class ChallengeConsume {
  const ChallengeConsume({required this.slot, required this.at, required this.modulus, required this.offset});
  final bool slot;
  final int at, modulus, offset;

  int valueOf(int gate) => gate % modulus + offset;
}

class ChallengeLevel {
  const ChallengeLevel({
    required this.id,
    required this.game,
    required this.tier,
    required this.difficulty,
    required this.expected,
    required this.inputs,
    required this.output,
    required this.letter,
    required this.state,
    required this.submissions,
    required this.errors,
    required this.minimum,
    required this.gate,
    required this.consume,
    required this.extraOf,
    required this.puzzle,
  });
  final String id, game, tier;
  final int difficulty;
  // 预计用时（服务器按真实过关用时回调过的）。
  final Duration expected;
  final List<String> inputs;
  final String? output;
  // 这一关碎片的字母（A、B…），加试题为空。
  final String? letter;
  final ChallengeLevelState state;
  // 交过几次（下一次交的号）、错交次数（含答案里自带的失误）。
  final int submissions, errors;
  // 要用最少步数时的最少步数。
  final int? minimum;
  final ChallengeGate? gate;
  final ChallengeConsume? consume;
  // 加试题是为哪一关加的。
  final String? extraOf;
  // 题面（开着或过了时才有，过了的可以重做一遍再看碎片），按这个游戏的规则解码。
  final Object? puzzle;
}

class ChallengeResult {
  const ChallengeResult({required this.points, required this.awarded, required this.ending});
  final int points, awarded;
  // cleared 全过、stuck 剩下的开不了、timeout 到点、ended 提前结束。
  final String ending;
}

class ChallengeRun {
  const ChallengeRun({
    required this.runId,
    required this.challengeId,
    required this.title,
    required this.label,
    required this.timeLimit,
    required this.startedAt,
    required this.deadline,
    required this.serverTime,
    required this.running,
    required this.penalty,
    required this.ending,
    required this.levels,
    required this.result,
  });
  final String runId, challengeId, title, label;
  final Duration timeLimit;
  // 服务器时刻（UTC）；本机按 serverTime 与收到时的本机时刻算偏差再倒计时。到点时刻已扣掉门与终章输错的时间（penalty）。
  final DateTime startedAt, deadline, serverTime;
  final bool running;
  final Duration penalty;
  final ChallengeFinal ending;
  final List<ChallengeLevel> levels;
  final ChallengeResult? result;

  ChallengeLevel level(String id) => levels.firstWhere((level) => level.id == id);
}

// 交一次答案的结果：fragment 是过关给的碎片（只在这次回复里有），extra 是快得不正常追加的加试题。
class ChallengeVerdict {
  const ChallengeVerdict({required this.correct, required this.fragment, required this.extra, required this.run});
  final bool correct;
  final int? fragment;
  final String? extra;
  final ChallengeRun run;
}

// 开门或输终章的结果：错了已扣时间（到点时刻往前挪）。
class ChallengeEntry {
  const ChallengeEntry({required this.correct, required this.run});
  final bool correct;
  final ChallengeRun run;
}

// 余额与等级：等级 Lv0–Lv5 按近 12 个月获得的总数 earned 算（花了不减），nextLevelAt 是到下一级要的获得总数，最高级为空
// （[人工决策-2026-11-14 20:20:18] 见服务端 src/modules/points/points_level.ts）。
const pointsLevelCount = 6;

class PointsSummary {
  const PointsSummary({required this.balance, required this.expiring, required this.expiringAt, required this.earned, required this.level, required this.nextLevelAt});
  final int balance, expiring, earned, level;
  final DateTime? expiringAt;
  final int? nextLevelAt;
}

class PointsEntry {
  const PointsEntry({required this.id, required this.kind, required this.amount, required this.note, required this.at});
  final String id, kind, note;
  final int amount;
  final DateTime at;
}

class PointsBatch {
  const PointsBatch({required this.entries, required this.next});
  final List<PointsEntry> entries;
  final String? next;
}

// 失败：notSignedIn 是没登录应用账号（或已在别处注销）；runActive 附进行中那一局的编号；runOver、levelLocked 附服务器那边的现状；pointsShort 是积分不够付门票。
enum ChallengeFailure { notSignedIn, notFound, unavailable, runActive, runNotFound, runOver, levelLocked, pointsShort, network, rateLimited, failed }

class ChallengeException implements Exception {
  const ChallengeException(this.failure, this.message, {this.runId, this.run});
  final ChallengeFailure failure;
  final String message;
  final String? runId;
  final ChallengeRun? run;
  @override
  String toString() => 'ChallengeException($failure)';
}

// 中转端口（social 实现）：用这个应用账号的设备密钥签名。games 是这个版本玩得了的游戏 id。
abstract interface class ChallengeClient {
  Future<ChallengeCatalog> catalog(AppAccountRef account, Set<String> games);
  Future<ChallengeRun> start(AppAccountRef account, String challengeId, Set<String> games);
  Future<ChallengeRun> run(AppAccountRef account, String runId);
  // attempt 是这一关之前交过几次；没收到回复时用同一个号重发，服务器只算一次。
  Future<ChallengeVerdict> answer(AppAccountRef account, String runId, String levelId, int attempt, Object? answer);
  // 开门（levelId 是门后面那一关）与输终章的最终密码。
  Future<ChallengeEntry> gate(AppAccountRef account, String runId, String levelId, int value);
  Future<ChallengeEntry> finale(AppAccountRef account, String runId, int value);
  Future<ChallengeRun> end(AppAccountRef account, String runId);
  Future<PointsSummary> points(AppAccountRef account);
  Future<PointsBatch> pointsEntries(AppAccountRef account, {String? before});
  // 删掉服务器上这个应用账号的积分、挑战成绩与解锁记录（娱乐与积分的「删除数据」，人工决策见 domain/leisure.dart）。
  Future<void> deleteData(AppAccountRef account);
}

// 游乐场经它用挑战与积分（application 实现，组合根注入）：跟着当前的应用账号走；登录状态变了 changes 发一次。
abstract interface class ChallengeHub {
  Stream<void> get changes;
  // 这台设备登录着应用账号。
  bool get signedIn;
  Future<ChallengeCatalog> catalog(Set<String> games);
  Future<ChallengeRun> start(String challengeId, Set<String> games);
  Future<ChallengeRun> run(String runId);
  Future<ChallengeVerdict> answer(String runId, String levelId, int attempt, Object? answer);
  Future<ChallengeEntry> gate(String runId, String levelId, int value);
  Future<ChallengeEntry> finale(String runId, int value);
  Future<ChallengeRun> end(String runId);
  Future<PointsSummary> points();
  Future<PointsBatch> pointsEntries({String? before});
}
