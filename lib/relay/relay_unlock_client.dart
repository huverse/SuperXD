import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/domain/unlock.dart';
import 'package:superxd/relay/account_relay.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/relay/relay_client.dart';

// 解锁的中转客户端（协议见 server/README.md「解锁」，规则见服务端 src/modules/unlock/unlock_rules.ts）：用这个应用账号的设备密钥签名（同挑战与积分）；
// 服务器的回复是外部输入，逐项校验，看不懂的按失败报。
class RelayUnlockClient implements UnlockClient {
  RelayUnlockClient({required this.vault, required RelayTransport transport}) : _relay = AccountRelay(vault: vault, transport: transport);
  final AppAccountVault vault;
  final AccountRelay _relay;

  // 回复只有等级与最多 rolloutUnlockLimit 个编号，16KB 足够。
  static const limit = 16 * 1024;

  static final _errors = RelayErrors(
    missingKey: const UnlockException(UnlockFailure.notSignedIn, '请先登录应用账号'),
    signedOut: const UnlockException(UnlockFailure.notSignedIn, '应用账号已经退出，请重新登录'),
    network: const UnlockException(UnlockFailure.network, '连不上服务器'),
    rateLimited: const UnlockException(UnlockFailure.rateLimited, '操作太频繁，请稍后再试'),
    failed: (code) => UnlockException(UnlockFailure.failed, '服务器暂时不可用（$code）'),
    codes: {
      RelayCode.unlockUnavailable: (_) => const UnlockException(UnlockFailure.unavailable, '这一项现在不能用积分解锁'),
      RelayCode.pointsShort: (error) => UnlockException(UnlockFailure.pointsShort, error.detail['price'] is int ? '积分不够，要 ${error.detail['price']} 分' : '积分不够'),
    },
  );

  Future<Map<String, Object?>> _send(AppAccountRef account, String method, String path) async => (await _relay.signedCall(account, method, path, limit: limit, errors: _errors)).body;

  static UnlockState _state(Map<String, Object?> body) {
    final level = body['level'], open = body['open'];
    if (level is int && level >= 0 && level < pointsLevelCount && open is List && open.length <= rolloutUnlockLimit && open.every((id) => id is String && rolloutIdPattern.hasMatch(id))) {
      return UnlockState(level: level, open: open.cast<String>().toSet());
    }
    campusLog('[Unlock] action=decode code=${RelayCode.badResponse}');
    throw const UnlockException(UnlockFailure.failed, '服务器的回复看不懂，请更新应用后再试');
  }

  @override
  Future<UnlockState> state(AppAccountRef account) async => _state(await _send(account, 'GET', '/v1/unlocks'));

  @override
  Future<UnlockState> buy(AppAccountRef account, String id) async => _state(await _send(account, 'POST', '/v1/unlocks/${Uri.encodeComponent(id)}/buy'));
}
