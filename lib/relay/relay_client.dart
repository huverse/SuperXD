import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/relay/relay_crypto.dart';

// [人工决策-2026-10-04 16:44:36] 私信经自建加密中转送达（NestJS + MySQL + Redis）；测试期用国内服务器 IP，之后换正式域名，地址不写死。
// 中转服务地址在构建时传入：--dart-define=SUPERXD_RELAY=http://IP:端口（正式环境换成 https 域名），不写进代码。
// 未传入时私信不可用，界面如实提示。
const relayBaseUrl = String.fromEnvironment('SUPERXD_RELAY');

// 错误码与服务端 server/src/common/relay_error.ts 一致，另加客户端侧的网络类错误码。只按 code 分支，message 只用于日志。
abstract final class RelayCode {
  static const invalidRequest = 'INVALID_REQUEST';
  static const unauthorized = 'UNAUTHORIZED';
  static const clockSkew = 'CLOCK_SKEW';
  static const replayed = 'REPLAYED';
  static const deviceMismatch = 'DEVICE_MISMATCH';
  static const rateLimited = 'RATE_LIMITED';
  static const inviteNotFound = 'INVITE_NOT_FOUND';
  static const inviteSelf = 'INVITE_SELF';
  static const inviteProofInvalid = 'INVITE_PROOF_INVALID';
  static const friendLimit = 'FRIEND_LIMIT';
  static const notFriend = 'NOT_FRIEND';
  static const peerNotFound = 'PEER_NOT_FOUND';
  static const envelopeTooLarge = 'ENVELOPE_TOO_LARGE';
  static const mailboxFull = 'MAILBOX_FULL';
  static const accountNotFound = 'ACCOUNT_NOT_FOUND';
  static const accountDeleted = 'ACCOUNT_DELETED'; // 这把密钥所在的应用账号已注销（只有应用账号的接口回它，别的照旧回 ACCOUNT_NOT_FOUND）
  static const usernameTaken = 'USERNAME_TAKEN'; // 注册时用户名已被占用
  static const credentialsInvalid = 'CREDENTIALS_INVALID'; // 用户名、密码或恢复码不对（不说是哪一项）
  static const joinNotFound = 'JOIN_NOT_FOUND'; // 扫码登录的票据已过期、核对码不对或不是这台设备发起的
  static const accountTooNew = 'ACCOUNT_TOO_NEW'; // 应用账号建立不满规定天数（节日抽奖），附 eligibleAt 毫秒
  static const challengeNotFound = 'CHALLENGE_NOT_FOUND';
  static const challengeUnavailable = 'CHALLENGE_UNAVAILABLE';
  static const runActive = 'RUN_ACTIVE';
  static const runNotFound = 'RUN_NOT_FOUND';
  static const runOver = 'RUN_OVER';
  static const levelLocked = 'LEVEL_LOCKED';
  static const pointsShort = 'POINTS_SHORT'; // 积分不够付这笔（如挑战门票），附 price 与 balance
  static const unlockUnavailable = 'UNLOCK_UNAVAILABLE'; // 没有这项解锁、已下架、已经公开或不能用积分买
  static const passUnavailable = 'PASS_UNAVAILABLE'; // 这项服务现在不用积分换时长（passes.json 里没有）
  static const diagnosticNotFound = 'DIAGNOSTIC_NOT_FOUND';
  static const socialElsewhere = 'SOCIAL_ELSEWHERE'; // 这个应用账号的私信在另一台设备上（没带接管）
  static const socialTaken = 'SOCIAL_TAKEN'; // 这个私信设备已挂在别的应用账号下
  static const internal = 'INTERNAL';
  // 以下只在客户端产生。
  static const network = 'NETWORK'; // 连不上服务器
  static const timeout = 'TIMEOUT'; // 请求超时（普通 15 秒，长轮询为挂起时长再加 10 秒）
  static const badResponse = 'BAD_RESPONSE'; // 响应不是约定的格式（含超过响应上限）
}

class RelayException implements Exception {
  const RelayException(this.code, {this.retryAfter, this.detail = const {}});
  final String code;
  final int? retryAfter;
  // 错误响应的其余字段（积分不够时的 price、账号太新时的 eligibleAt、挑战的现状等），外部输入，用时逐项校验。
  final Map<String, Object?> detail;
  @override
  String toString() => 'RelayException($code)';
}

class RelayResponse {
  const RelayResponse(this.status, this.body, {this.headers = const {}});
  final int status;
  final Map<String, Object?> body;
  // 回复头（键是小写）；条件请求读 ETag。测试的假中转可以不给。
  final Map<String, String> headers;
}

// 传输端口：生产用 HTTP，测试用内存假服务。
abstract interface class RelayTransport {
  // timeout 为空用传输的默认超时；长轮询按挂起时长另给。limit 是响应字节上限，为空用传输的默认值，拉信箱按这次要的条数另给。
  // background 为真是持续接收通道的长轮询（私信收消息）：断网与超时不在这里记错误，由调用方的接收循环按连续失败次数决定。
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout, int? limit, bool background = false});
}

class HttpRelayTransport implements RelayTransport {
  HttpRelayTransport(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 15), this.signals}) : _http = CampusHttp('relay', client: client);
  final String baseUrl;
  final Duration timeout;
  final CampusHttp _http;
  // 每条回复头里的灰度版本号报给它（人工决策见 domain/rollout.dart 的 RolloutSignals）；为空不报。
  final RolloutSignals? signals;

  // 默认的响应上限，只防异常响应占满内存：中转的普通接口只回几个字段，最大的好友列表（500 个）约 30KB。
  static const responseLimit = 64 * 1024;

  // 超时管整个请求（连接、发送、读完响应体），到点中断连接；响应边读边限长。都在共用内核 CampusHttp，开发者模式下的请求记录也由它记。
  @override
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout, int? limit, bool background = false}) async {
    final uri = Uri.parse('$baseUrl$pathWithQuery');
    // 日志只记方法与路径（不含服务器地址与查询参数），原始异常与堆栈留在日志里，往上只抛错误码。
    final route = '$method ${pathWithQuery.split('?').first}';
    final http.Response response;
    try {
      response = await _http.send(method, uri, timeout: timeout ?? this.timeout, limit: limit ?? responseLimit, headers: headers, bodyBytes: body);
    } on CampusHttpTooLarge catch (error, stack) {
      _log(route, RelayCode.badResponse, error, stack);
      throw const RelayException(RelayCode.badResponse);
    } on TimeoutException catch (error, stack) {
      if (!background) _log(route, RelayCode.timeout, error, stack);
      throw const RelayException(RelayCode.timeout);
    } on SocketException catch (error, stack) {
      if (!background) _log(route, RelayCode.network, error, stack);
      throw const RelayException(RelayCode.network);
    } on http.ClientException catch (error, stack) {
      if (!background) _log(route, RelayCode.network, error, stack);
      throw const RelayException(RelayCode.network);
    }
    signals?.observe(response.headers);
    if (response.statusCode == 204 || response.bodyBytes.isEmpty) return RelayResponse(response.statusCode, const {}, headers: response.headers);
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) return RelayResponse(response.statusCode, decoded.cast<String, Object?>(), headers: response.headers);
      campusLog('[RelayTransport] action=request route=$route code=${RelayCode.badResponse} status=${response.statusCode} errorType=${decoded.runtimeType}');
    } on FormatException catch (error, stack) {
      _log(route, RelayCode.badResponse, error, stack, status: response.statusCode);
    }
    throw const RelayException(RelayCode.badResponse);
  }

  static void _log(String route, String code, Object error, StackTrace stack, {int? status}) =>
      campusLog('[RelayTransport] action=request route=$route code=$code${status == null ? '' : ' status=$status'} errorType=${error.runtimeType}\n$stack');

  void close() => _http.close();
}

// [人工决策-2026-11-15 19:18:31] 好友列表里带的公钥（换了设备的好友、新手机接管拿名单）由服务器签名（用户选「服务器签名新公钥」，没选「中转改 HTTPS」）：
// 中转是明文 HTTP，同一网络里的人能把好友的新公钥换成自己的、之后的私信就被他看到；服务器用在线签名钥签（服务端 src/modules/friend/friend_key_signer.ts），
// 这里内置它的公钥，带公钥的每一条都要有任一把验得过的签名，不然整份当格式不对（social/social_relay.dart 的 friends）。只挡网络上的人，挡不住服务器本身。换钥时先在这里加新公钥、发版后再换服务器的。
// [人工决策-2026-11-17 21:24:25] 明文 HTTP 期间只给两类关键回复加服务器认证（用户选定，不做通用回复签名）：同一把在线签名钥（服务端 src/common/crypto/relay_signer.ts）
// 另签奖品信封（relay_reward_client.dart 的 openRewardPrize）与「账号已注销」（本文件 request），各带域前缀、不能互相挪用；这份公钥由 relayFriendKeys 改名 relayServerKeys。
const relayServerKeys = ['hPOt9e7eTElfw24qcN7bccM1K3-rHX9KtVHCwhn-xaI'];

// 服务器在线签名钥签的原文：任一把受信公钥（base64url）验得过才算服务器发的。
Future<bool> verifyRelaySignature(List<String> serverKeys, List<int> message, List<int> signature) async {
  for (final trusted in serverKeys) {
    if (await verifyEd25519(tryDecodeBase64UrlNoPad(trusted, length: 32)!, message, signature)) return true;
  }
  return false;
}

// 协议 v1 的签名请求：每个请求用设备签名私钥签名（方法、路径、时间、随机数、请求体哈希），没有会话令牌；接口路径由调用方给。
// 应用账号与它签名的各个客户端、私信（social/social_relay.dart）都经它发。serverKeys 是受信的服务器在线签名公钥（base64url），默认内置的；测试换成测试钥。
class RelayClient {
  RelayClient(this.transport, {this.serverKeys = relayServerKeys});
  final RelayTransport transport;
  final List<String> serverKeys;
  // 本机时钟与服务器的差（毫秒）。收到 CLOCK_SKEW 时按服务器时间校正，并只重发这一次。
  int clockOffset = 0;

  // 用给定身份签名发一个请求，返回响应体；错误响应的其余字段放在 RelayException.detail。
  // timeout 为空用传输的默认值（长轮询另给）；limit 为空用传输的默认响应上限；background 见 RelayTransport。
  Future<Map<String, Object?>> request(RelayIdentity identity, String method, String path, {Map<String, Object?>? payload, Duration? timeout, int? limit, bool background = false}) async =>
      (await exchange(identity, method, path, payload: payload, timeout: timeout, limit: limit, background: background)).body;

  // 同 request，另可加请求头（条件请求的 If-None-Match），返回整条回复：2xx 与 304（没变，回复体为空）算成功，其余同 request 抛 RelayException。
  Future<RelayResponse> exchange(RelayIdentity identity, String method, String path, {Map<String, Object?>? payload, Duration? timeout, int? limit, bool background = false, Map<String, String> headers = const {}}) async {
    final body = payload == null ? <int>[] : utf8.encode(jsonEncode(payload));
    for (var attempt = 0;; attempt++) {
      final time = '${DateTime.now().millisecondsSinceEpoch + clockOffset}';
      final nonce = base64UrlNoPad(secureRandomBytes(16));
      final signature = await identity.sign(requestCanonical(method, path, time, nonce, body));
      final response = await transport.send(method, path, {
        'x-sxd-device': identity.deviceId,
        'x-sxd-time': time,
        'x-sxd-nonce': nonce,
        'x-sxd-signature': base64UrlNoPad(signature),
        'content-type': 'application/json',
        ...headers,
      }, payload == null ? null : body, timeout: timeout, limit: limit, background: background);
      if ((response.status >= 200 && response.status < 300) || response.status == 304) return response;
      final code = response.body['code'];
      if (code is! String) throw const RelayException(RelayCode.badResponse);
      final serverTime = response.body['serverTime'];
      if (code == RelayCode.clockSkew && serverTime is int && attempt == 0) {
        clockOffset = serverTime - DateTime.now().millisecondsSinceEpoch;
        continue;
      }
      if (code == RelayCode.accountDeleted && !await _deletionProven(identity.deviceId, nonce, response.body['proof'])) {
        campusLog('[Relay] action=account_deleted errorType=signature route=$method ${path.split('?').first}');
        throw const RelayException(RelayCode.network);
      }
      final retryAfter = response.body['retryAfter'];
      throw RelayException(code, retryAfter: retryAfter is int ? retryAfter : null, detail: response.body);
    }
  }

  // [人工决策-2026-11-17 21:24:25] 「账号已注销」要服务器签名（用户选「只给两类关键回复加认证」）：收到它会不可逆地清掉本机那个账号的私信与私信身份私钥，
  // 明文 HTTP 下同一网络里的人伪造一条就够了。服务器的 proof 是对「这把密钥的设备号、这次请求的随机数」的签名（原文见 relay_crypto.dart 的 accountDeletedCanonical，
  // 服务端 src/modules/account/account_deleted_proof.ts）：随机数每次新起，截下来的旧证明对这次请求验不过。没有或验不过当连不上（NETWORK），什么也不删。
  Future<bool> _deletionProven(String deviceId, String nonce, Object? proof) async {
    final signature = proof is String ? tryDecodeBase64UrlNoPad(proof, length: 64) : null;
    return signature != null && await verifyRelaySignature(serverKeys, accountDeletedCanonical(deviceId, nonce), signature);
  }

  // 登记这台设备的密钥（自签名、幂等）。
  Future<void> register(RelayIdentity identity) =>
      request(identity, 'POST', '/v1/devices', payload: {'signPublicKey': base64UrlNoPad(identity.signPublicKey), 'boxPublicKey': base64UrlNoPad(identity.boxPublicKey)});

  // 删除本设备：服务端删掉本设备的好友关系、待收消息与注册记录；应用账号退出时删它的设备密钥也用这个。
  Future<void> deleteDevice(RelayIdentity identity) => request(identity, 'DELETE', '/v1/devices');
}
