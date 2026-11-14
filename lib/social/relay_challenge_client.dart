import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_client.dart';

// 挑战与积分的中转客户端（协议见 server/README.md「挑战与积分」，人工决策见 lib/playground/challenge/challenge_rules.dart）：
// 用这个应用账号的设备密钥签名（同 RelayAppAccountClient，密钥在安全存储 superxd_account 的 account.slot），校时重发一次复用 RelayClient；
// 服务器的回复是外部输入，逐项校验，看不懂的按失败报、不猜。
class RelayChallengeClient implements ChallengeClient {
  RelayChallengeClient({required this.vault, required RelayTransport transport}) : _relay = RelayClient(transport);
  final AppAccountVault vault;
  final RelayClient _relay;

  // 一局的回复里带着开着的几关题面（专家档十二连环一开局有 7 关），放宽到 256KB。
  static const runLimit = 256 * 1024;

  static String _games(Set<String> games) => (games.toList()..sort()).join(',');

  Future<Map<String, Object?>> _send(AppAccountRef account, String method, String path, [Map<String, Object?>? payload]) async {
    final saved = await vault.read(account.slot);
    if (saved == null) throw const ChallengeException(ChallengeFailure.notSignedIn, '请先登录应用账号');
    try {
      return await _relay.request(saved.identity, method, path, payload, null, runLimit);
    } on RelayException catch (error) {
      final detail = error.detail;
      final run = detail['run'] is Map ? _tryRun(detail['run']) : null;
      throw switch (error.code) {
        RelayCode.accountNotFound || RelayCode.unauthorized => const ChallengeException(ChallengeFailure.notSignedIn, '应用账号已经退出，请重新登录'),
        RelayCode.challengeNotFound => const ChallengeException(ChallengeFailure.notFound, '这个挑战已经结束了'),
        RelayCode.challengeUnavailable => const ChallengeException(ChallengeFailure.unavailable, '这个挑战暂时开不了，请稍后再试或更新应用'),
        RelayCode.runActive => ChallengeException(ChallengeFailure.runActive, '还有一局没结束', runId: detail['runId'] is String ? detail['runId'] as String : null),
        RelayCode.runNotFound => const ChallengeException(ChallengeFailure.runNotFound, '这一局找不到了'),
        RelayCode.runOver => ChallengeException(ChallengeFailure.runOver, '这一局已经结束', run: run),
        RelayCode.levelLocked => ChallengeException(ChallengeFailure.levelLocked, '这一关现在不能交', run: run),
        RelayCode.rateLimited => const ChallengeException(ChallengeFailure.rateLimited, '操作太频繁，请稍后再试'),
        RelayCode.network || RelayCode.timeout => const ChallengeException(ChallengeFailure.network, '连不上服务器'),
        _ => ChallengeException(ChallengeFailure.failed, '服务器暂时不可用（${error.code}）'),
      };
    }
  }

  static Never _bad(String what) {
    campusLog('[Challenge] action=decode code=${RelayCode.badResponse} what=$what');
    throw const ChallengeException(ChallengeFailure.failed, '服务器的回复看不懂，请更新应用后再试');
  }

  static T _field<T>(Map<Object?, Object?> json, String key) => switch (json[key]) {
    final T value => value,
    _ => _bad(key),
  };

  static DateTime _time(Map<Object?, Object?> json, String key) => DateTime.fromMillisecondsSinceEpoch(_field<int>(json, key), isUtc: true);

  static List<String> _strings(Map<Object?, Object?> json, String key) => [for (final item in _field<List<Object?>>(json, key)) item is String ? item : _bad(key)];

  static ChallengeRun? _tryRun(Object? json) {
    try {
      return _run(json);
    } on ChallengeException {
      return null;
    }
  }

  static ChallengeRun _run(Object? raw) {
    if (raw is! Map) _bad('run');
    final result = raw['result'];
    return ChallengeRun(
      runId: _field<String>(raw, 'runId'),
      challengeId: _field<String>(raw, 'challengeId'),
      title: _field<String>(raw, 'title'),
      label: _field<String>(raw, 'label'),
      timeLimit: Duration(seconds: _field<int>(raw, 'timeLimit')),
      startedAt: _time(raw, 'startedAt'),
      deadline: _time(raw, 'deadline'),
      serverTime: _time(raw, 'serverTime'),
      running: switch (raw['state']) {
        'running' => true,
        'settled' => false,
        _ => _bad('state'),
      },
      levels: [for (final level in _field<List<Object?>>(raw, 'levels')) _level(level)],
      result: result is Map ? ChallengeResult(points: _field<int>(result, 'points'), awarded: _field<int>(result, 'awarded'), ending: _field<String>(result, 'ending')) : null,
    );
  }

  static ChallengeLevel _level(Object? raw) {
    if (raw is! Map) _bad('level');
    final key = raw['key'], teaser = raw['teaser'], output = raw['output'];
    return ChallengeLevel(
      id: _field<String>(raw, 'id'),
      game: _field<String>(raw, 'game'),
      tier: _field<String>(raw, 'tier'),
      difficulty: _field<int>(raw, 'difficulty'),
      inputs: _strings(raw, 'inputs'),
      output: output is String ? output : null,
      state: ChallengeLevelState.values.where((state) => state.name == raw['state']).firstOrNull ?? _bad('levelState'),
      submissions: _field<int>(raw, 'submissions'),
      errors: _field<int>(raw, 'errors'),
      key: key is int ? key : null,
      teaser: teaser is String ? teaser : null,
      puzzle: raw['puzzle'],
      keyed: [
        for (final item in _field<List<Object?>>(raw, 'keyed'))
          if (item is Map) ChallengeKeyed(from: _field<String>(item, 'from'), at: _field<int>(item, 'at'), key: _field<int>(item, 'key')) else _bad('keyed'),
      ],
    );
  }

  @override
  Future<ChallengeCatalog> catalog(AppAccountRef account, Set<String> games) async {
    final body = await _send(account, 'GET', '/v1/challenges?games=${_games(games)}');
    final active = body['activeRun'];
    return ChallengeCatalog(
      serverTime: _time(body, 'serverTime'),
      activeRun: active is String ? active : null,
      challenges: [
        for (final item in _field<List<Object?>>(body, 'challenges'))
          if (item is Map)
            ChallengeSummary(
              id: _field<String>(item, 'id'),
              title: _field<String>(item, 'title'),
              label: _field<String>(item, 'label'),
              levels: _field<int>(item, 'levels'),
              timeLimit: Duration(seconds: _field<int>(item, 'timeLimit')),
              endsAt: _time(item, 'endsAt'),
              best: item['best'] is int ? item['best'] as int : null,
              playable: _field<bool>(item, 'playable'),
            )
          else
            _bad('challenge'),
      ],
    );
  }

  @override
  Future<ChallengeRun> start(AppAccountRef account, String challengeId, Set<String> games) async =>
      _run(await _send(account, 'POST', '/v1/challenges/${Uri.encodeComponent(challengeId)}/runs', {'games': (games.toList()..sort())}));

  @override
  Future<ChallengeRun> run(AppAccountRef account, String runId) async => _run(await _send(account, 'GET', '/v1/challenge-runs/$runId'));

  @override
  Future<ChallengeVerdict> answer(AppAccountRef account, String runId, String levelId, int attempt, Object? answer) async {
    final body = await _send(account, 'POST', '/v1/challenge-runs/$runId/levels/$levelId/answers', {'attempt': attempt, 'answer': answer});
    final key = body['key'];
    return ChallengeVerdict(correct: _field<bool>(body, 'correct'), key: key is int ? key : null, run: _run(body['run']));
  }

  @override
  Future<ChallengeRun> end(AppAccountRef account, String runId) async => _run(await _send(account, 'POST', '/v1/challenge-runs/$runId/end'));

  @override
  Future<PointsSummary> points(AppAccountRef account) async {
    final body = await _send(account, 'GET', '/v1/points');
    final expiringAt = body['expiringAt'];
    return PointsSummary(balance: _field<int>(body, 'balance'), expiring: _field<int>(body, 'expiring'), expiringAt: expiringAt is int ? DateTime.fromMillisecondsSinceEpoch(expiringAt, isUtc: true) : null);
  }

  @override
  Future<PointsBatch> pointsEntries(AppAccountRef account, {String? before}) async {
    final body = await _send(account, 'GET', before == null ? '/v1/points/entries' : '/v1/points/entries?before=$before');
    final next = body['next'];
    return PointsBatch(
      entries: [
        for (final item in _field<List<Object?>>(body, 'entries'))
          if (item is Map)
            PointsEntry(id: _field<String>(item, 'id'), kind: _field<String>(item, 'kind'), amount: _field<int>(item, 'amount'), note: _field<String>(item, 'note'), at: _time(item, 'at'))
          else
            _bad('entry'),
      ],
      next: next is String ? next : null,
    );
  }
}
