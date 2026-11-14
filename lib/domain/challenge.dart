import 'package:superxd/domain/account.dart';

// 挑战与积分（人工决策见 lib/playground/challenge/challenge_rules.dart 与服务端 src/modules/points/points.service.ts）：
// 服务器下发挑战、出题、逐关核对、计时（不暂停）与结算，积分属于应用账号。这里是两边共用的类型与端口，协议见 server/README.md「挑战与积分」。

enum ChallengeLevelState { locked, open, solved, failed }

class ChallengeSummary {
  const ChallengeSummary({required this.id, required this.title, required this.label, required this.levels, required this.timeLimit, required this.endsAt, required this.best, required this.playable});
  final String id, title, label;
  final int levels;
  final Duration timeLimit;
  final DateTime endsAt;
  // 这个应用账号在这个挑战上的最好成绩，没玩过为空。
  final int? best;
  // 里面有这个版本没有的游戏时为假（要更新应用）。
  final bool playable;
}

class ChallengeCatalog {
  const ChallengeCatalog({required this.serverTime, required this.activeRun, required this.challenges});
  final DateTime serverTime;
  final String? activeRun;
  final List<ChallengeSummary> challenges;
}

// 收钥匙的关里由钥匙补上的一处：from 是给钥匙的关，at 是位置（24 点第几张牌、八皇后第几行、数回第几格），key 是钥匙数。
class ChallengeKeyed {
  const ChallengeKeyed({required this.from, required this.at, required this.key});
  final String from;
  final int at, key;
}

class ChallengeLevel {
  const ChallengeLevel({
    required this.id,
    required this.game,
    required this.tier,
    required this.difficulty,
    required this.inputs,
    required this.output,
    required this.state,
    required this.submissions,
    required this.errors,
    required this.key,
    required this.teaser,
    required this.puzzle,
    required this.keyed,
  });
  final String id, game, tier;
  final int difficulty;
  final List<String> inputs;
  final String? output;
  final ChallengeLevelState state;
  // 交过几次（下一次交的号）、错交次数（含答案里自带的失误）。
  final int submissions, errors;
  // 解开后给的钥匙数。
  final int? key;
  // 锁着时的预告（挖掉的写 ?）。
  final String? teaser;
  // 题面（开着时才有），按这个游戏的规则解码。
  final Object? puzzle;
  final List<ChallengeKeyed> keyed;
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
    required this.levels,
    required this.result,
  });
  final String runId, challengeId, title, label;
  final Duration timeLimit;
  // 服务器时刻（UTC）；本机按 serverTime 与收到时的本机时刻算偏差再倒计时。
  final DateTime startedAt, deadline, serverTime;
  final bool running;
  final List<ChallengeLevel> levels;
  final ChallengeResult? result;

  ChallengeLevel level(String id) => levels.firstWhere((level) => level.id == id);
}

class ChallengeVerdict {
  const ChallengeVerdict({required this.correct, required this.key, required this.run});
  final bool correct;
  final int? key;
  final ChallengeRun run;
}

class PointsSummary {
  const PointsSummary({required this.balance, required this.expiring, required this.expiringAt});
  final int balance, expiring;
  final DateTime? expiringAt;
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

// 失败：notSignedIn 是没登录应用账号（或已在别处注销）；runActive 附进行中那一局的编号；runOver、levelLocked 附服务器那边的现状。
enum ChallengeFailure { notSignedIn, notFound, unavailable, runActive, runNotFound, runOver, levelLocked, network, rateLimited, failed }

class ChallengeException implements Exception {
  const ChallengeException(this.failure, this.message, {this.runId, this.run});
  final ChallengeFailure failure;
  final String message;
  final String? runId;
  final ChallengeRun? run;
  @override
  String toString() => 'ChallengeException($failure)';
}

// 中转端口（social 实现）：用这个教务账号对应的应用账号设备密钥签名。games 是这个版本玩得了的游戏 id。
abstract interface class ChallengeClient {
  Future<ChallengeCatalog> catalog(AccountIdentity identity, Set<String> games);
  Future<ChallengeRun> start(AccountIdentity identity, String challengeId, Set<String> games);
  Future<ChallengeRun> run(AccountIdentity identity, String runId);
  // attempt 是这一关之前交过几次；没收到回复时用同一个号重发，服务器只算一次。
  Future<ChallengeVerdict> answer(AccountIdentity identity, String runId, String levelId, int attempt, Object? answer);
  Future<ChallengeRun> end(AccountIdentity identity, String runId);
  Future<PointsSummary> points(AccountIdentity identity);
  Future<PointsBatch> pointsEntries(AccountIdentity identity, {String? before});
}

// 游乐场经它用挑战与积分（application 实现，组合根注入）：跟着当前教务账号的应用账号走；登录状态变了 changes 发一次。
abstract interface class ChallengeHub {
  Stream<void> get changes;
  // 当前教务账号登录了应用账号。
  bool get signedIn;
  // 登录着教务（没登录教务时页面引导先登录教务）。
  bool get campusSignedIn;
  Future<ChallengeCatalog> catalog(Set<String> games);
  Future<ChallengeRun> start(String challengeId, Set<String> games);
  Future<ChallengeRun> run(String runId);
  Future<ChallengeVerdict> answer(String runId, String levelId, int attempt, Object? answer);
  Future<ChallengeRun> end(String runId);
  Future<PointsSummary> points();
  Future<PointsBatch> pointsEntries({String? before});
}
