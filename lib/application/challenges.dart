import 'dart:async';

import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/gateway/account_access.dart';

// 挑战与积分的编排（设备级，切换教务账号不重建；人工决策见 lib/playground/challenge/challenge_rules.dart）：跟着当前教务账号的应用账号走，
// 游乐场经 ChallengeHub 用。没登录应用账号时不联网、直接报 notSignedIn；中转说这个应用账号已不在（别处注销、被清理）就让 AppAccounts 马上核一次，
// 本机随之退回未登录，页面引导重新登录。
class Challenges implements ChallengeHub {
  Challenges({required this.accounts, required this.appAccounts, required this.client}) {
    accounts.addListener(_changed);
    appAccounts.addListener(_changed);
  }
  final AccountAccess accounts;
  final AppAccounts appAccounts;
  final ChallengeClient client;
  final _changes = StreamController<void>.broadcast();
  var _signedIn = false, _campus = false;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  bool get campusSignedIn => accounts.activeIdentity != null;

  @override
  bool get signedIn => campusSignedIn && appAccounts.accountId != null;

  void _changed() {
    if (signedIn == _signedIn && campusSignedIn == _campus) return;
    _signedIn = signedIn;
    _campus = campusSignedIn;
    _changes.add(null);
  }

  Future<T> _with<T>(String action, Future<T> Function(AccountIdentity identity) work) async {
    final identity = accounts.activeIdentity;
    if (identity == null || appAccounts.accountId == null) throw const ChallengeException(ChallengeFailure.notSignedIn, '请先登录应用账号');
    try {
      return await work(identity);
    } on ChallengeException catch (error) {
      campusLog('[Challenges] action=$action failure=${error.failure.name}');
      if (error.failure == ChallengeFailure.notSignedIn) unawaited(appAccounts.check(force: true));
      rethrow;
    }
  }

  @override
  Future<ChallengeCatalog> catalog(Set<String> games) => _with('catalog', (identity) => client.catalog(identity, games));

  @override
  Future<ChallengeRun> start(String challengeId, Set<String> games) => _with('start', (identity) => client.start(identity, challengeId, games));

  @override
  Future<ChallengeRun> run(String runId) => _with('run', (identity) => client.run(identity, runId));

  @override
  Future<ChallengeVerdict> answer(String runId, String levelId, int attempt, Object? answer) => _with('answer', (identity) => client.answer(identity, runId, levelId, attempt, answer));

  @override
  Future<ChallengeRun> end(String runId) => _with('end', (identity) => client.end(identity, runId));

  @override
  Future<PointsSummary> points() => _with('points', client.points);

  @override
  Future<PointsBatch> pointsEntries({String? before}) => _with('points_entries', (identity) => client.pointsEntries(identity, before: before));
}
