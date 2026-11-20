import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/relay/account_relay.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/relay/relay_client.dart';

// 灰度点名的中转客户端（人工决策见 domain/rollout.dart 文件头 11-16 那条，服务端 src/modules/flag_target）：GET /v1/flags/mine，
// 用这个应用账号的设备密钥签名（同解锁），回复带账号建立的时刻；回复是外部输入，按 decodeRolloutTargets 逐项校验。没登录或账号不在了为空，连不上抛 RolloutException。
// 11-20 起认条件请求（人工决策见 domain/rollout.dart 的 RolloutSignals）：带上次的版本号来，没变中转回 304、不查库，这里给出 targets 为空。
class RelayFlagTargetClient implements RolloutTargetClient {
  RelayFlagTargetClient({required this.vault, required RelayTransport transport}) : _relay = AccountRelay(vault: vault, transport: transport);
  final AppAccountVault vault;
  final AccountRelay _relay;

  // 最多 rolloutTargetLimit 个编号加到期时刻，32KB 足够。
  static const limit = 32 * 1024;

  @override
  Future<RolloutTargetsFetch?> mine(AppAccountRef account, {String? etag}) async {
    final RelayResponse reply;
    try {
      final response = await _relay.exchange(account, 'GET', '/v1/flags/mine', headers: {if (etag != null) 'if-none-match': '"$etag"'}, limit: limit);
      if (response == null) return null;
      reply = response;
    } on RelayException catch (error) {
      if (error.code == RelayCode.accountNotFound || error.code == RelayCode.unauthorized) return null;
      throw RolloutException('问点名失败（${error.code}）');
    }
    final current = rolloutEtagOf(reply.headers['etag']);
    if (reply.status == 304) return RolloutTargetsFetch(null, etag: current ?? etag);
    try {
      return RolloutTargetsFetch(decodeRolloutTargets(reply.body), etag: current);
    } on FormatException catch (error, stack) {
      campusLog('[Rollouts] action=targets_decode code=${RelayCode.badResponse} message=${error.message}\n$stack');
      throw const RolloutException('点名的回复看不懂');
    }
  }
}
