import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/diagnostic_upload.dart';
import 'package:superxd/domain/festival.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/domain/unlock.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/relay/relay_app_account.dart';
import 'package:superxd/relay/relay_challenge_client.dart';
import 'package:superxd/relay/relay_client.dart';
import 'package:superxd/relay/relay_crypto.dart';
import 'package:superxd/relay/relay_diagnostic_account.dart';
import 'package:superxd/relay/relay_flag_target_client.dart';
import 'package:superxd/relay/relay_reward_client.dart';
import 'package:superxd/relay/relay_unlock_client.dart';

import 'fake_relay.dart';

// 应用账号签名的各个中转客户端把中转的错误码换成本模块异常的整张表（审查 P2-3 抽出共用的签名调用时钉住：类型、分类与文案逐项不变）。
// 中转按这次要测的错误码回复；NETWORK 与 TIMEOUT 由传输抛出（同 HttpRelayTransport）；「账号已注销」带用测试钥签的证明。

class _Scripted implements RelayTransport {
  _Scripted(this.reply);
  final Future<RelayResponse> Function(Map<String, String> headers) reply;
  final calls = <String>[];
  @override
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout, int? limit, bool background = false}) {
    calls.add('$method ${pathWithQuery.split('?').first} limit=$limit');
    return reply(headers);
  }
}

const _account = AppAccountRef(accountId: 'acct-synthetic', slot: 'account.synthetic');

// 一个错误码对应的中转回复；NETWORK、TIMEOUT 由传输抛出。
Future<RelayResponse> Function(Map<String, String>) _failing(String code, {Map<String, Object?> extra = const {}}) => (headers) async {
  if (code == RelayCode.network || code == RelayCode.timeout) throw RelayException(code);
  if (code == RelayCode.accountDeleted) {
    final proof = await FakeRelay().serverSign(accountDeletedCanonical(headers['x-sxd-device']!, headers['x-sxd-nonce']!));
    return RelayResponse(410, {'code': code, 'proof': base64UrlNoPad(proof)});
  }
  return RelayResponse(400, {'code': code, 'message': code, ...extra});
};

String _describe(Object error) => switch (error) {
  UnlockException() => 'Unlock ${error.failure.name} ${error.message}',
  ChallengeException() => 'Challenge ${error.failure.name} ${error.message} runId=${error.runId} run=${error.run != null}',
  DiagnosticNotSignedIn() => 'DiagnosticNotSignedIn ${error.message}',
  DiagnosticUploadException() => 'Diagnostic ${error.message}',
  FestivalNotSignedIn() => 'FestivalNotSignedIn ${error.message}',
  FestivalException() => 'Festival ${error.message}',
  RolloutException() => 'Rollout ${error.message}',
  AppAccountException() => 'AppAccount ${error.failure.name} ${error.message}',
  _ => 'unexpected ${error.runtimeType}',
};

Future<String> _outcome(Future<Object?> Function() call) async {
  try {
    final result = await call();
    return switch (result) {
      null => 'null',
      FestivalTooNew(:final eligibleAt) => 'FestivalTooNew $eligibleAt',
      _ => 'ok ${result.runtimeType}',
    };
  } catch (error) {
    return _describe(error);
  }
}

void main() {
  late MemoryAppAccountVault vault;
  setUp(() async {
    vault = MemoryAppAccountVault();
    await vault.write(_account.slot, AppAccountKey(identity: await RelayIdentity.generate(), accountId: _account.accountId));
  });

  // 每个错误码跑一遍，返回「错误码 → 结果」。
  Future<Map<String, String>> table<C>(List<(String, Map<String, Object?>)> codes, C Function(RelayTransport transport) build, Future<Object?> Function(C client) call) async => {
    for (final (code, extra) in codes) '$code${extra.isEmpty ? '' : ' $extra'}': await _outcome(() => call(build(_Scripted(_failing(code, extra: extra))))),
  };

  test('解锁：没登录两种文案、业务码、通用几类', () async {
    final missing = _Scripted(_failing(RelayCode.internal));
    expect(await _outcome(() => RelayUnlockClient(vault: MemoryAppAccountVault(), transport: missing).state(_account)), 'Unlock notSignedIn 请先登录应用账号');
    expect(missing.calls, isEmpty, reason: '没有这把密钥不发请求');
    final calls = _Scripted(_failing(RelayCode.internal));
    await _outcome(() => RelayUnlockClient(vault: vault, transport: calls).buy(_account, 'game.x'));
    expect(calls.calls, ['POST /v1/unlocks/game.x/buy limit=${RelayUnlockClient.limit}']);
    expect(await table([
      (RelayCode.accountNotFound, {}),
      (RelayCode.unauthorized, {}),
      (RelayCode.unlockUnavailable, {}),
      (RelayCode.pointsShort, {'price': 300}),
      (RelayCode.pointsShort, {}),
      (RelayCode.rateLimited, {}),
      (RelayCode.network, {}),
      (RelayCode.timeout, {}),
      (RelayCode.internal, {}),
    ], (transport) => RelayUnlockClient(vault: vault, transport: transport), (client) => client.state(_account)), {
      'ACCOUNT_NOT_FOUND': 'Unlock notSignedIn 应用账号已经退出，请重新登录',
      'UNAUTHORIZED': 'Unlock notSignedIn 应用账号已经退出，请重新登录',
      'UNLOCK_UNAVAILABLE': 'Unlock unavailable 这一项现在不能用积分解锁',
      'POINTS_SHORT {price: 300}': 'Unlock pointsShort 积分不够，要 300 分',
      'POINTS_SHORT': 'Unlock pointsShort 积分不够',
      'RATE_LIMITED': 'Unlock rateLimited 操作太频繁，请稍后再试',
      'NETWORK': 'Unlock network 连不上服务器',
      'TIMEOUT': 'Unlock network 连不上服务器',
      'INTERNAL': 'Unlock failed 服务器暂时不可用（INTERNAL）',
    });
  });

  test('诊断包：没登录、诊断包不在、通用几类', () async {
    final missing = _Scripted(_failing(RelayCode.internal));
    expect(await _outcome(() => RelayDiagnosticAccountClient(vault: MemoryAppAccountVault(), transport: missing).list(_account)), 'DiagnosticNotSignedIn 应用账号已经退出，请重新登录');
    expect(missing.calls, isEmpty);
    expect(await table([
      (RelayCode.accountNotFound, {}),
      (RelayCode.unauthorized, {}),
      (RelayCode.diagnosticNotFound, {}),
      (RelayCode.rateLimited, {}),
      (RelayCode.network, {}),
      (RelayCode.timeout, {}),
      (RelayCode.invalidRequest, {}),
    ], (transport) => RelayDiagnosticAccountClient(vault: vault, transport: transport), (client) => client.delete(_account, '7KQ2M9XD')), {
      'ACCOUNT_NOT_FOUND': 'DiagnosticNotSignedIn 应用账号已经退出，请重新登录',
      'UNAUTHORIZED': 'DiagnosticNotSignedIn 应用账号已经退出，请重新登录',
      'DIAGNOSTIC_NOT_FOUND': 'Diagnostic 诊断包不存在或已经删除',
      'RATE_LIMITED': 'Diagnostic 操作太频繁，请稍后再试',
      'NETWORK': 'Diagnostic 连不上服务器',
      'TIMEOUT': 'Diagnostic 连不上服务器',
      'INVALID_REQUEST': 'Diagnostic 服务器暂时不可用（INVALID_REQUEST）',
    });
  });

  test('挑战：没登录两种文案、带编号与现状的业务码、通用几类，一局放宽响应上限', () async {
    final missing = _Scripted(_failing(RelayCode.internal));
    expect(await _outcome(() => RelayChallengeClient(vault: MemoryAppAccountVault(), transport: missing).points(_account)), 'Challenge notSignedIn 请先登录应用账号 runId=null run=false');
    expect(missing.calls, isEmpty);
    final calls = _Scripted(_failing(RelayCode.internal));
    await _outcome(() => RelayChallengeClient(vault: vault, transport: calls).points(_account));
    expect(calls.calls, ['GET /v1/points limit=${RelayChallengeClient.runLimit}']);
    expect(await table([
      (RelayCode.accountNotFound, {}),
      (RelayCode.unauthorized, {}),
      (RelayCode.challengeNotFound, {}),
      (RelayCode.challengeUnavailable, {}),
      (RelayCode.runActive, {'runId': 'run-synthetic'}),
      (RelayCode.runActive, {}),
      (RelayCode.runNotFound, {}),
      (RelayCode.runOver, {}),
      (RelayCode.runOver, {'run': {'runId': 1}}),
      (RelayCode.levelLocked, {}),
      (RelayCode.pointsShort, {'price': 300}),
      (RelayCode.pointsShort, {}),
      (RelayCode.rateLimited, {}),
      (RelayCode.network, {}),
      (RelayCode.timeout, {}),
      (RelayCode.internal, {}),
    ], (transport) => RelayChallengeClient(vault: vault, transport: transport), (client) => client.end(_account, 'run-synthetic')), {
      'ACCOUNT_NOT_FOUND': 'Challenge notSignedIn 应用账号已经退出，请重新登录 runId=null run=false',
      'UNAUTHORIZED': 'Challenge notSignedIn 应用账号已经退出，请重新登录 runId=null run=false',
      'CHALLENGE_NOT_FOUND': 'Challenge notFound 这个挑战已经结束了 runId=null run=false',
      'CHALLENGE_UNAVAILABLE': 'Challenge unavailable 这个挑战暂时开不了，请稍后再试或更新应用 runId=null run=false',
      'RUN_ACTIVE {runId: run-synthetic}': 'Challenge runActive 还有一局没结束 runId=run-synthetic run=false',
      'RUN_ACTIVE': 'Challenge runActive 还有一局没结束 runId=null run=false',
      'RUN_NOT_FOUND': 'Challenge runNotFound 这一局找不到了 runId=null run=false',
      'RUN_OVER': 'Challenge runOver 这一局已经结束 runId=null run=false',
      'RUN_OVER {run: {runId: 1}}': 'Challenge runOver 这一局已经结束 runId=null run=false',
      'LEVEL_LOCKED': 'Challenge levelLocked 现在不能交 runId=null run=false',
      'POINTS_SHORT {price: 300}': 'Challenge pointsShort 积分不够，门票要 300 分 runId=null run=false',
      'POINTS_SHORT': 'Challenge pointsShort 积分不够 runId=null run=false',
      'RATE_LIMITED': 'Challenge rateLimited 操作太频繁，请稍后再试 runId=null run=false',
      'NETWORK': 'Challenge network 连不上服务器 runId=null run=false',
      'TIMEOUT': 'Challenge network 连不上服务器 runId=null run=false',
      'INTERNAL': 'Challenge failed 服务器暂时不可用（INTERNAL） runId=null run=false',
    });
  });

  test('灰度点名：没登录与账号不在为空，其余一律问点名失败', () async {
    final missing = _Scripted(_failing(RelayCode.internal));
    expect(await _outcome(() => RelayFlagTargetClient(vault: MemoryAppAccountVault(), transport: missing).mine(_account)), 'null');
    expect(missing.calls, isEmpty);
    expect(await table([
      (RelayCode.accountNotFound, {}),
      (RelayCode.unauthorized, {}),
      (RelayCode.rateLimited, {}),
      (RelayCode.network, {}),
      (RelayCode.timeout, {}),
      (RelayCode.internal, {}),
    ], (transport) => RelayFlagTargetClient(vault: vault, transport: transport), (client) => client.mine(_account)), {
      'ACCOUNT_NOT_FOUND': 'null',
      'UNAUTHORIZED': 'null',
      'RATE_LIMITED': 'Rollout 问点名失败（RATE_LIMITED）',
      'NETWORK': 'Rollout 问点名失败（NETWORK）',
      'TIMEOUT': 'Rollout 问点名失败（TIMEOUT）',
      'INTERNAL': 'Rollout 问点名失败（INTERNAL）',
    });
  });

  test('节日抽签与活动状态：没登录、账号太新是结果（没给时刻按其余错误）、通用几类', () async {
    final missing = _Scripted(_failing(RelayCode.internal));
    expect(await _outcome(() => RelayRewardClient(vault: MemoryAppAccountVault(), transport: missing).draw(_account, 'c-1', occasion: 'c-1', activeDays: 3)), 'FestivalNotSignedIn 没有登录应用账号');
    expect(await _outcome(() => RelayRewardClient(vault: MemoryAppAccountVault(), transport: missing).status(_account, 'c-1')), 'FestivalNotSignedIn 没有登录应用账号');
    expect(missing.calls, isEmpty);
    final codes = [
      (RelayCode.accountNotFound, <String, Object?>{}),
      (RelayCode.unauthorized, <String, Object?>{}),
      (RelayCode.accountTooNew, <String, Object?>{'eligibleAt': DateTime.utc(2027, 2, 9).millisecondsSinceEpoch}),
      (RelayCode.accountTooNew, <String, Object?>{}),
      (RelayCode.rateLimited, <String, Object?>{}),
      (RelayCode.network, <String, Object?>{}),
      (RelayCode.timeout, <String, Object?>{}),
      (RelayCode.internal, <String, Object?>{}),
    ];
    final eligible = 'ACCOUNT_TOO_NEW {eligibleAt: ${DateTime.utc(2027, 2, 9).millisecondsSinceEpoch}}';
    expect(await table(codes, (transport) => RelayRewardClient(vault: vault, transport: transport), (client) => client.draw(_account, 'c-1', occasion: 'c-1', activeDays: 3)), {
      'ACCOUNT_NOT_FOUND': 'FestivalNotSignedIn 没有登录应用账号',
      'UNAUTHORIZED': 'FestivalNotSignedIn 没有登录应用账号',
      eligible: 'FestivalTooNew ${DateTime.utc(2027, 2, 9)}',
      'ACCOUNT_TOO_NEW': 'Festival 服务器暂时不可用（ACCOUNT_TOO_NEW）',
      'RATE_LIMITED': 'Festival 请求过于频繁',
      'NETWORK': 'Festival 连不上服务器',
      'TIMEOUT': 'Festival 连不上服务器',
      'INTERNAL': 'Festival 服务器暂时不可用（INTERNAL）',
    });
    expect(await table(codes, (transport) => RelayRewardClient(vault: vault, transport: transport), (client) => client.status(_account, 'c-1')), {
      'ACCOUNT_NOT_FOUND': 'FestivalNotSignedIn 没有登录应用账号',
      'UNAUTHORIZED': 'FestivalNotSignedIn 没有登录应用账号',
      eligible: 'Festival 服务器暂时不可用（ACCOUNT_TOO_NEW）',
      'ACCOUNT_TOO_NEW': 'Festival 服务器暂时不可用（ACCOUNT_TOO_NEW）',
      'RATE_LIMITED': 'Festival 请求过于频繁',
      'NETWORK': 'Festival 连不上服务器',
      'TIMEOUT': 'Festival 连不上服务器',
      'INTERNAL': 'Festival 服务器暂时不可用（INTERNAL）',
    });
  });

  test('应用账号：登录与查看账号的业务码、带证明的「账号已注销」、通用几类', () async {
    final codes = [
      (RelayCode.usernameTaken, <String, Object?>{}),
      (RelayCode.credentialsInvalid, <String, Object?>{}),
      (RelayCode.joinNotFound, <String, Object?>{}),
      (RelayCode.accountNotFound, <String, Object?>{}),
      (RelayCode.unauthorized, <String, Object?>{}),
      (RelayCode.accountDeleted, <String, Object?>{}),
      (RelayCode.rateLimited, <String, Object?>{}),
      (RelayCode.network, <String, Object?>{}),
      (RelayCode.timeout, <String, Object?>{}),
      (RelayCode.invalidRequest, <String, Object?>{}),
      (RelayCode.internal, <String, Object?>{}),
    ];
    const expected = {
      'USERNAME_TAKEN': 'AppAccount usernameTaken 用户名已被占用',
      'CREDENTIALS_INVALID': 'AppAccount credentialsInvalid 用户名或密码不对',
      'JOIN_NOT_FOUND': 'AppAccount joinExpired 二维码已过期或不对，请刷新',
      'ACCOUNT_NOT_FOUND': 'AppAccount notSignedIn 应用账号已经退出',
      'UNAUTHORIZED': 'AppAccount notSignedIn 应用账号已经退出',
      'ACCOUNT_DELETED': 'AppAccount deleted 应用账号已注销',
      'RATE_LIMITED': 'AppAccount rateLimited 尝试太频繁，请稍后再试',
      'NETWORK': 'AppAccount network 连不上服务器',
      'TIMEOUT': 'AppAccount network 连不上服务器',
      'INVALID_REQUEST': 'AppAccount failed 信息没能交给服务器，请更新应用后再试',
      'INTERNAL': 'AppAccount failed 服务器暂时不可用（INTERNAL）',
    };
    RelayAppAccountClient build(RelayTransport transport) => RelayAppAccountClient(vault: vault, transport: transport, serverKeys: FakeRelay.serverKeys);
    expect(await table(codes, build, (client) => client.login('tester_one', 'synthetic-pass')), expected);
    final summary = <String, String>{};
    for (final (code, extra) in codes) {
      await vault.write(appAccountSlot, AppAccountKey(identity: await RelayIdentity.generate(), accountId: 'a' * 22, username: 'tester_one'));
      summary[code] = await _outcome(() => build(_Scripted(_failing(code, extra: extra))).summary());
    }
    expect(summary, expected);
  });
}
