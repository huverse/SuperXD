import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/relay/relay_client.dart';
import 'package:superxd/relay/relay_crypto.dart';

// 签名请求的回复体与签名用的那把设备密钥（奖品信封要用它解开）。
typedef SignedReply = ({Map<String, Object?> body, RelayIdentity identity});

// 中转的失败换成本模块在 domain 登记的异常（RelayException 不出 relay 层，application 与 page 只认各自的异常）：
// 没登录、连不上、太频繁与其余四类各个账号签名的客户端都有，怎么分只在 of 里写一处；模块只给各类换成什么（异常类型与文案各自不同），自己的业务码放 codes。
class RelayErrors {
  const RelayErrors({required this.signedOut, required this.network, required this.rateLimited, required this.failed, this.missingKey, this.codes = const {}});
  // 中转说账号不在了或不认这把密钥（ACCOUNT_NOT_FOUND、UNAUTHORIZED）。
  final Exception signedOut;
  // 这台手机上没有这把密钥（不发请求）；为空同 signedOut。
  final Exception? missingKey;
  // 连不上或超时（NETWORK、TIMEOUT；原始异常与堆栈已由传输层记进日志）。
  final Exception network;
  // 限流（RATE_LIMITED）。
  final Exception rateLimited;
  // 其余错误码。
  final Exception Function(String code) failed;
  // 模块自己的业务码（与上面几类不重叠）。
  final Map<String, Exception Function(RelayException error)> codes;

  Exception of(RelayException error) => switch (codes[error.code]) {
    final custom? => custom(error),
    null => switch (error.code) {
      RelayCode.accountNotFound || RelayCode.unauthorized => signedOut,
      RelayCode.network || RelayCode.timeout => network,
      RelayCode.rateLimited => rateLimited,
      final code => failed(code),
    },
  };
}

// 用应用账号的设备密钥签名访问中转的共用调用（审查 P2-3：以前应用账号、挑战与积分、节日抽签、解锁、点名、诊断包认领各抄一份
// 「读密钥 → 签名发出 → 错误码换成本模块异常」）。签名、校时重发一次与「账号已注销」的核对在 RelayClient，超时与响应上限在传输；
// 每个客户端各持一份（各自的校时偏差，同以前），不重试。
class AccountRelay {
  AccountRelay({required this.vault, required RelayTransport transport, List<String> serverKeys = relayServerKeys}) : _relay = RelayClient(transport, serverKeys: serverKeys);
  final AppAccountVault vault;
  final RelayClient _relay;

  // 本机时钟与服务器的差（毫秒）。
  int get clockOffset => _relay.clockOffset;

  // 11-28 复核 F01：回复回来时，这个账号在本机的密钥已经不是发请求的那把（请求在路上时换了账号、退出了、同一账号重新登录换了新密钥），
  // 这条回复属于已经结束的那次登录：不交给调用方（签名请求算没登录、send 与 exchange 返回空），免得旧登录的结果写进新登录的状态。
  // 请求本身已经发出、中转那边已经做了，按密钥的设备号比（一次登录一把）；出错的回复照常抛（「账号已注销」这类要按原账号处理）。
  Future<bool> _current(AppAccountRef account, RelayIdentity identity, String method) async {
    if ((await vault.keyOf(account))?.identity.deviceId == identity.deviceId) return true;
    campusLog('[AccountRelay] action=drop_stale_reply method=$method');
    return false;
  }

  // 用这个应用账号在本机的设备密钥（安全存储里 account.slot 指的那把，账号号也要对得上，见 keyOf）签名发一个请求；没有这把密钥抛 errors.missingKey、不发请求，
  // 回来时密钥已经换了同样抛（见 _current）；中转的错误码按 errors 换成本模块的异常。limit 为空用传输的默认响应上限。
  Future<SignedReply> signedCall(AppAccountRef account, String method, String path, {Map<String, Object?>? payload, int? limit, required RelayErrors errors}) async {
    final saved = await vault.keyOf(account);
    if (saved == null) throw errors.missingKey ?? errors.signedOut;
    final body = await signedWith(saved.identity, method, path, payload: payload, limit: limit, errors: errors);
    if (!await _current(account, saved.identity, method)) throw errors.missingKey ?? errors.signedOut;
    return (body: body, identity: saved.identity);
  }

  // 用给定的密钥签名（应用账号注册、登录与扫码出示时新生成的那把，或登录着的那把），中转的错误码按 errors 换成本模块的异常。
  Future<Map<String, Object?>> signedWith(RelayIdentity identity, String method, String path, {Map<String, Object?>? payload, int? limit, required RelayErrors errors}) async {
    try {
      return await _relay.request(identity, method, path, payload: payload, limit: limit);
    } on RelayException catch (error) {
      throw errors.of(error);
    }
  }

  // 同 signedCall，但没有这把密钥时返回空、中转的错误码原样抛 RelayException：给要按错误码返回结果而不是抛异常的调用方（灰度点名、节日抽签的账号太新）。
  Future<SignedReply?> send(AppAccountRef account, String method, String path, {Map<String, Object?>? payload, int? limit}) async {
    final saved = await vault.keyOf(account);
    if (saved == null) return null;
    final body = await _relay.request(saved.identity, method, path, payload: payload, limit: limit);
    return await _current(account, saved.identity, method) ? (body: body, identity: saved.identity) : null;
  }

  // 同 send，另可加请求头、拿整条回复（304 算成功）：给条件请求（灰度点名带上次的版本号）。
  Future<RelayResponse?> exchange(AppAccountRef account, String method, String path, {Map<String, String> headers = const {}, int? limit}) async {
    final saved = await vault.keyOf(account);
    if (saved == null) return null;
    final response = await _relay.exchange(saved.identity, method, path, limit: limit, headers: headers);
    return await _current(account, saved.identity, method) ? response : null;
  }
}
