import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/pass.dart';
import 'package:superxd/relay/account_relay.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/relay/relay_client.dart';

// 积分时长券的中转客户端（规则见服务端 src/modules/pass/pass.service.ts）：清单 GET /v1/app/passes 免签名、不带标识，
// 自己的券与购买用这个应用账号的设备密钥签名（同解锁）；服务器的回复是外部输入，逐项校验，看不懂的按失败报。
class RelayPassClient implements PassClient {
  RelayPassClient({required this.vault, required RelayTransport transport}) : _transport = transport, _relay = AccountRelay(vault: vault, transport: transport);
  final AppAccountVault vault;
  final RelayTransport _transport;
  final AccountRelay _relay;

  // 回复最多 passOfferLimit 项，16KB 足够。
  static const limit = 16 * 1024;

  static final _errors = RelayErrors(
    missingKey: const PassException(PassFailure.notSignedIn, '请先登录应用账号'),
    signedOut: const PassException(PassFailure.notSignedIn, '应用账号已经退出，请重新登录'),
    network: const PassException(PassFailure.network, '连不上服务器'),
    rateLimited: const PassException(PassFailure.rateLimited, '操作太频繁，请稍后再试'),
    failed: (code) => PassException(PassFailure.failed, '服务器暂时不可用（$code）'),
    codes: {
      RelayCode.passUnavailable: (_) => const PassException(PassFailure.unavailable, '这项服务现在不用积分换时长'),
      RelayCode.pointsShort: (error) => PassException(PassFailure.pointsShort, error.detail['price'] is int ? '积分不够，要 ${error.detail['price']} 分' : '积分不够'),
    },
  );

  T _decode<T>(T Function() decode) {
    try {
      return decode();
    } on FormatException catch (error) {
      campusLog('[Pass] action=decode code=${RelayCode.badResponse} message=${error.message}');
      throw const PassException(PassFailure.failed, '服务器的回复看不懂，请更新应用后再试');
    }
  }

  @override
  Future<List<PassOffer>> offers() async {
    final RelayResponse response;
    try {
      response = await _transport.send('GET', '/v1/app/passes', const {}, null, limit: limit);
    } on RelayException catch (error) {
      campusLog('[Pass] action=offers code=${error.code}');
      throw error.code == RelayCode.rateLimited ? _errors.rateLimited : _errors.network;
    }
    return _decode(() => decodePassOffers(response.body));
  }

  @override
  Future<Map<String, DateTime>> held(AppAccountRef account) async {
    final body = await _body(account, 'GET', '/v1/passes');
    return _decode(() => decodePassHeld(body));
  }

  @override
  Future<Map<String, DateTime>> buy(AppAccountRef account, String id) async {
    final body = await _body(account, 'POST', '/v1/passes/${Uri.encodeComponent(id)}/buy');
    return _decode(() => decodePassHeld(body));
  }

  Future<Map<String, Object?>> _body(AppAccountRef account, String method, String path) async => (await _relay.signedCall(account, method, path, limit: limit, errors: _errors)).body;
}
