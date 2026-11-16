import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_client.dart';

// 灰度点名的中转客户端（人工决策见 domain/rollout.dart 文件头 11-16 那条，服务端 src/modules/flag_target）：GET /v1/flags/mine，
// 用这个应用账号的设备密钥签名（同解锁），回复带账号建立的时刻；回复是外部输入，按 decodeRolloutTargets 逐项校验。没登录或账号不在了为空，连不上抛 RolloutException。
class RelayFlagTargetClient implements RolloutTargetClient {
  RelayFlagTargetClient({required this.vault, required RelayTransport transport}) : _relay = RelayClient(transport);
  final AppAccountVault vault;
  final RelayClient _relay;

  // 最多 rolloutTargetLimit 个编号加到期时刻，32KB 足够。
  static const limit = 32 * 1024;

  @override
  Future<RolloutTargets?> mine(AppAccountRef account) async {
    final saved = await vault.read(account.slot);
    if (saved == null) return null;
    final Map<String, Object?> body;
    try {
      body = await _relay.request(saved.identity, 'GET', '/v1/flags/mine', null, null, limit);
    } on RelayException catch (error) {
      if (error.code == RelayCode.accountNotFound || error.code == RelayCode.unauthorized) return null;
      throw RolloutException('问点名失败（${error.code}）');
    }
    try {
      return decodeRolloutTargets(body);
    } on FormatException catch (error, stack) {
      campusLog('[Rollouts] action=targets_decode code=${RelayCode.badResponse} message=${error.message}\n$stack');
      throw const RolloutException('点名的回复看不懂');
    }
  }
}
