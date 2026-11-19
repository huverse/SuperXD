import 'dart:async';

import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/challenge.dart';

// 挑战与积分的编排（设备级，切换教务账号不重建；人工决策见 lib/playground/challenge/challenge_rules.dart）：跟着当前的应用账号走（只认 AppAccountRef，见 domain/app_account.dart），
// 游乐场经 ChallengeHub 用。没登录应用账号时不联网、直接报 notSignedIn；中转说这个应用账号已不在（别处注销、被清理）就让 AppAccounts 马上核一次，
// 本机随之退回未登录，页面引导重新登录。当前应用账号变了（含直接换成另一个账号）发 changes。
class Challenges implements ChallengeHub {
  Challenges({required this.appAccounts, required this.client}) : _account = appAccounts.current {
    appAccounts.addListener(_changed);
  }
  final AppAccounts appAccounts;
  final ChallengeClient client;
  final _changes = StreamController<void>.broadcast();
  // 上次通知时的应用账号：登录、退出与直接换成另一个账号都发 changes（挑战一栏要按新账号重读）。
  AppAccountRef? _account;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  bool get signedIn => appAccounts.current != null;

  void _changed() {
    final account = appAccounts.current;
    if (account == _account) return;
    _account = account;
    _changes.add(null);
  }

  Future<T> _with<T>(String action, Future<T> Function(AppAccountRef account) work) async {
    final account = appAccounts.current;
    if (account == null) throw const ChallengeException(ChallengeFailure.notSignedIn, '请先登录应用账号');
    try {
      return await work(account);
    } on ChallengeException catch (error) {
      campusLog('[Challenges] action=$action failure=${error.failure.name}');
      if (error.failure == ChallengeFailure.notSignedIn) unawaited(appAccounts.check(force: true));
      rethrow;
    }
  }

  @override
  Future<ChallengeCatalog> catalog(Set<String> games) => _with('catalog', (account) => client.catalog(account, games));

  @override
  Future<ChallengeRun> start(String challengeId, Set<String> games) => _with('start', (account) => client.start(account, challengeId, games));

  @override
  Future<ChallengeRun> run(String runId) => _with('run', (account) => client.run(account, runId));

  @override
  Future<ChallengeVerdict> answer(String runId, String levelId, int attempt, Object? answer) => _with('answer', (account) => client.answer(account, runId, levelId, attempt, answer));

  @override
  Future<ChallengeEntry> gate(String runId, String levelId, int value) => _with('gate', (account) => client.gate(account, runId, levelId, value));

  @override
  Future<ChallengeEntry> finale(String runId, int value) => _with('finale', (account) => client.finale(account, runId, value));

  @override
  Future<ChallengeRun> end(String runId) => _with('end', (account) => client.end(account, runId));

  @override
  Future<PointsSummary> points() => _with('points', client.points);

  @override
  Future<PointsBatch> pointsEntries({String? before}) => _with('points_entries', (account) => client.pointsEntries(account, before: before));

  // 应用账号页「删除游乐场与积分」（application/leisure.dart 调，不在给游乐场的 ChallengeHub 里）：删服务器上当前应用账号的积分、挑战与解锁。
  Future<void> deleteData() => _with('delete_data', client.deleteData);
}
