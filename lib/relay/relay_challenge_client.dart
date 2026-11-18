import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/relay/relay_client.dart';

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
      return await _relay.request(saved.identity, method, path, payload: payload, limit: runLimit);
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
        RelayCode.levelLocked => ChallengeException(ChallengeFailure.levelLocked, '现在不能交', run: run),
        RelayCode.pointsShort => ChallengeException(ChallengeFailure.pointsShort, detail['price'] is int ? '积分不够，门票要 ${detail['price']} 分' : '积分不够'),
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
      penalty: Duration(seconds: _field<int>(raw, 'penaltySeconds')),
      ending: ChallengeFinal.values.where((state) => state.name == raw['final']).firstOrNull ?? _bad('final'),
      levels: _graph([for (final level in _field<List<Object?>>(raw, 'levels')) _level(level)]),
      result: result is Map ? ChallengeResult(points: _field<int>(result, 'points'), awarded: _field<int>(result, 'awarded'), ending: _field<String>(result, 'ending')) : null,
    );
  }

  // 关卡图是外部输入，按服务端模板的同一规则核对（server/src/modules/challenge/challenge_config.ts）：编号不重复、引用的关都在、不指向自己、
  // 每关的碎片只交给一关、不成环；不合格当看不懂（引用不在的关会让 ChallengeRun.level 抛错，成环会让总览与首页缩略图无限递归）。
  static List<ChallengeLevel> _graph(List<ChallengeLevel> levels) {
    final ids = {for (final level in levels) level.id};
    if (ids.length != levels.length) _bad('levels');
    final next = <String, String>{};
    for (final level in levels) {
      for (final input in level.inputs) {
        if (input == level.id || !ids.contains(input) || next.containsKey(input)) _bad('inputs');
        next[input] = level.id;
      }
      if (level.extraOf case final extra? when extra == level.id || !ids.contains(extra)) _bad('extraOf');
    }
    _acyclic(next);
    return levels;
  }

  // 每个点最多一条出边：沿出边走回到走过的点就是环。
  static void _acyclic<T>(Map<T, T> next) {
    for (final start in next.keys) {
      final seen = <T>{};
      for (T? at = start; at != null; at = next[at]) {
        if (!seen.add(at)) _bad('cycle');
      }
    }
  }

  // 首页缩略图的边：两端都在这一个挑战的关里、不指向自己、每关一条出边、不成环。
  static List<(int, int)> _edges(Object? raw, int levels) {
    final edges = [
      for (final edge in raw is List ? raw : _bad('edges'))
        if (edge case [final int from, final int to] when from >= 0 && to >= 0 && from < levels && to < levels && from != to) (from, to) else _bad('edges'),
    ];
    final next = <int, int>{};
    for (final (from, to) in edges) {
      if (next.containsKey(from)) _bad('edges');
      next[from] = to;
    }
    _acyclic(next);
    return edges;
  }

  static ChallengeLevel _level(Object? raw) {
    if (raw is! Map) _bad('level');
    final output = raw['output'], letter = raw['letter'], minimum = raw['minimum'], gate = raw['gate'], consume = raw['consume'], extra = raw['extraOf'];
    return ChallengeLevel(
      id: _field<String>(raw, 'id'),
      game: _field<String>(raw, 'game'),
      tier: _field<String>(raw, 'tier'),
      difficulty: _field<int>(raw, 'difficulty'),
      expected: Duration(seconds: _field<int>(raw, 'expected')),
      inputs: _strings(raw, 'inputs'),
      output: output is String ? output : null,
      letter: letter is String ? letter : null,
      state: ChallengeLevelState.values.where((state) => state.name == raw['state']).firstOrNull ?? _bad('levelState'),
      submissions: _field<int>(raw, 'submissions'),
      errors: _field<int>(raw, 'errors'),
      minimum: minimum is int ? minimum : null,
      gate: switch (gate) {
        null => null,
        final Map<Object?, Object?> map => ChallengeGate(
          product: switch (map['op']) {
            'product' => true,
            'sum' => false,
            _ => _bad('gate'),
          },
          value: map['value'] is int ? map['value'] as int : null,
        ),
        _ => _bad('gate'),
      },
      consume: switch (consume) {
        null => null,
        final Map<Object?, Object?> map when _field<int>(map, 'modulus') > 0 => ChallengeConsume(
          slot: switch (map['kind']) {
            'slot' => true,
            'goal' => false,
            _ => _bad('consume'),
          },
          at: _field<int>(map, 'at'),
          modulus: _field<int>(map, 'modulus'),
          offset: _field<int>(map, 'offset'),
        ),
        _ => _bad('consume'),
      },
      extraOf: extra is String ? extra : null,
      puzzle: raw['puzzle'],
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
              tiers: _strings(item, 'tiers'),
              edges: _edges(item['edges'], _field<int>(item, 'levels')),
              timeLimit: Duration(seconds: _field<int>(item, 'timeLimit')),
              endsAt: _time(item, 'endsAt'),
              best: item['best'] is int ? item['best'] as int : null,
              playable: _field<bool>(item, 'playable'),
              ticket: _field<int>(item, 'ticket'),
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
    final fragment = body['fragment'], extra = body['extra'];
    return ChallengeVerdict(correct: _field<bool>(body, 'correct'), fragment: fragment is int ? fragment : null, extra: extra is String ? extra : null, run: _run(body['run']));
  }

  @override
  Future<ChallengeEntry> gate(AppAccountRef account, String runId, String levelId, int value) async => _entry(await _send(account, 'POST', '/v1/challenge-runs/$runId/gates/$levelId', {'value': value}));

  @override
  Future<ChallengeEntry> finale(AppAccountRef account, String runId, int value) async => _entry(await _send(account, 'POST', '/v1/challenge-runs/$runId/final', {'value': value}));

  static ChallengeEntry _entry(Map<String, Object?> body) => ChallengeEntry(correct: _field<bool>(body, 'correct'), run: _run(body['run']));

  @override
  Future<ChallengeRun> end(AppAccountRef account, String runId) async => _run(await _send(account, 'POST', '/v1/challenge-runs/$runId/end'));

  @override
  Future<PointsSummary> points(AppAccountRef account) async {
    final body = await _send(account, 'GET', '/v1/points');
    final expiringAt = body['expiringAt'], next = body['nextLevelAt'];
    final level = _field<int>(body, 'level');
    if (level < 0 || level >= pointsLevelCount) _bad('level');
    return PointsSummary(
      balance: _field<int>(body, 'balance'),
      expiring: _field<int>(body, 'expiring'),
      expiringAt: expiringAt is int ? DateTime.fromMillisecondsSinceEpoch(expiringAt, isUtc: true) : null,
      earned: _field<int>(body, 'earned'),
      level: level,
      nextLevelAt: next is int ? next : null,
    );
  }

  @override
  Future<void> deleteData(AppAccountRef account) async {
    await _send(account, 'DELETE', '/v1/leisure');
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
