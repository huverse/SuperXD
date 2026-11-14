import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/social/social_crypto.dart';

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
  static const accountRejected = 'ACCOUNT_REJECTED';
  static const captchaExpired = 'CAPTCHA_EXPIRED';
  static const upstreamUnavailable = 'UPSTREAM_UNAVAILABLE';
  static const accountNotFound = 'ACCOUNT_NOT_FOUND';
  static const challengeNotFound = 'CHALLENGE_NOT_FOUND';
  static const challengeUnavailable = 'CHALLENGE_UNAVAILABLE';
  static const runActive = 'RUN_ACTIVE';
  static const runNotFound = 'RUN_NOT_FOUND';
  static const runOver = 'RUN_OVER';
  static const levelLocked = 'LEVEL_LOCKED';
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
  // 错误响应的其余字段（应用账号登录被教务拒绝时的 reason、message 等），外部输入，用时逐项校验。
  final Map<String, Object?> detail;
  @override
  String toString() => 'RelayException($code)';
}

class RelayResponse {
  const RelayResponse(this.status, this.body);
  final int status;
  final Map<String, Object?> body;
}

// 传输端口：生产用 HTTP，测试用内存假服务。
abstract interface class RelayTransport {
  // timeout 为空用传输的默认超时；长轮询按挂起时长另给。limit 是响应字节上限，为空用传输的默认值，拉信箱按这次要的条数另给。
  // background 为真是收消息的长轮询：断网与超时不在这里记错误，由收取循环按连续失败次数决定（见 social_service.dart 的 liveFailureLimit）。
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout, int? limit, bool background = false});
}

class HttpRelayTransport implements RelayTransport {
  HttpRelayTransport(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 15)}) : _http = CampusHttp('relay', client: client);
  final String baseUrl;
  final Duration timeout;
  final CampusHttp _http;

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
    if (response.statusCode == 204 || response.bodyBytes.isEmpty) return RelayResponse(response.statusCode, const {});
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) return RelayResponse(response.statusCode, decoded.cast<String, Object?>());
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

class InboxItem {
  const InboxItem({required this.id, required this.from, required this.envelope, required this.createTime});
  final String id;
  final String from;
  final List<int> envelope;
  final int createTime;
}

// 协议 v1 的接口调用：每个请求用设备签名私钥签名（方法、路径、时间、随机数、请求体哈希），没有会话令牌。
class RelayClient {
  RelayClient(this.transport);
  final RelayTransport transport;
  // 本机时钟与服务器的差（毫秒）。收到 CLOCK_SKEW 时按服务器时间校正，并只重发这一次。
  int clockOffset = 0;

  // 拉信箱的响应上限按这次要的条数算：单条密文最多 256KB（服务端 relay_limits.ts 的 envelopeMaxBytes），经 base64url 约 342KB，
  // 加上消息号、发送方与时刻，每条按 360KB 算，再留普通接口那份余量（50 条约 18MB）。
  static int inboxLimit(int count) => count * 360 * 1024 + HttpRelayTransport.responseLimit;

  Future<Map<String, Object?>> _call(SocialIdentity identity, String method, String path, [Map<String, Object?>? payload, Duration? timeout, bool background = false, int? limit]) async {
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
      }, payload == null ? null : body, timeout: timeout, limit: limit, background: background);
      if (response.status >= 200 && response.status < 300) return response.body;
      final code = response.body['code'];
      if (code is! String) throw const RelayException(RelayCode.badResponse);
      final serverTime = response.body['serverTime'];
      if (code == RelayCode.clockSkew && serverTime is int && attempt == 0) {
        clockOffset = serverTime - DateTime.now().millisecondsSinceEpoch;
        continue;
      }
      final retryAfter = response.body['retryAfter'];
      throw RelayException(code, retryAfter: retryAfter is int ? retryAfter : null, detail: response.body);
    }
  }

  Future<void> register(SocialIdentity identity) =>
      _call(identity, 'POST', '/v1/devices', {'signPublicKey': base64UrlNoPad(identity.signPublicKey), 'boxPublicKey': base64UrlNoPad(identity.boxPublicKey)});

  // 删除本设备：服务端删掉本设备的好友关系、待收消息与注册记录。
  Future<void> deleteDevice(SocialIdentity identity) => _call(identity, 'DELETE', '/v1/devices');

  Future<int> createInvite(SocialIdentity identity, String inviteId, List<int> publicKey) async =>
      _integer((await _call(identity, 'POST', '/v1/invites', {'inviteId': inviteId, 'publicKey': base64UrlNoPad(publicKey)}))['expiresAt']);

  Future<void> revokeInvite(SocialIdentity identity, String inviteId) => _call(identity, 'DELETE', '/v1/invites/$inviteId');

  Future<int> redeem(SocialIdentity identity, {required String inviteId, required List<int> proof, required String helloId, required List<int> hello}) async {
    final body = await _call(identity, 'POST', '/v1/friends/redeem', {
      'inviteId': inviteId,
      'proof': base64UrlNoPad(proof),
      'hello': {'clientId': helloId, 'envelope': base64UrlNoPad(hello)},
    });
    return _integer(body['since']);
  }

  Future<Map<String, int>> friends(SocialIdentity identity) async {
    final list = (await _call(identity, 'GET', '/v1/friends'))['friends'];
    if (list is! List) throw const RelayException(RelayCode.badResponse);
    return {for (final item in list.cast<Map<Object?, Object?>>()) _text(item['deviceId']): _integer(item['since'])};
  }

  Future<void> removeFriend(SocialIdentity identity, String peerDeviceId) => _call(identity, 'DELETE', '/v1/friends/$peerDeviceId');

  Future<int> send(SocialIdentity identity, {required String to, required String clientId, required List<int> envelope}) async =>
      _integer((await _call(identity, 'POST', '/v1/messages', {'to': to, 'clientId': clientId, 'envelope': base64UrlNoPad(envelope)}))['createTime']);

  // wait 为长轮询挂起时长（服务端上限 25 秒）：没有消息时服务端挂起到有新消息或到时；本次请求超时放宽到挂起时长再加 10 秒。
  // 长轮询按后台请求发（background），断网与超时算不算错误交给收取循环。
  Future<({List<InboxItem> messages, bool more})> fetch(SocialIdentity identity, {String? after, int limit = 50, Duration? wait}) async {
    final query = '${after == null ? '' : 'after=$after&'}limit=$limit${wait == null ? '' : '&wait=${wait.inSeconds}'}';
    final body = await _call(identity, 'GET', '/v1/messages?$query', null, wait == null ? null : wait + const Duration(seconds: 10), wait != null, inboxLimit(limit));
    final list = body['messages'], more = body['more'];
    if (list is! List || more is! bool) throw const RelayException(RelayCode.badResponse);
    return (
      messages: [
        for (final item in list.cast<Map<Object?, Object?>>())
          InboxItem(id: _text(item['id']), from: _text(item['from']), envelope: decodeBase64UrlNoPad(_text(item['envelope'])), createTime: _integer(item['createTime'])),
      ],
      more: more,
    );
  }

  Future<void> ack(SocialIdentity identity, List<String> ids) => _call(identity, 'POST', '/v1/messages/ack', {'ids': ids});

  // 用给定身份签名发一个请求，返回响应体：应用账号、挑战与节日抽签都用这个应用账号的设备密钥发，接口路径由调用方给。
  // timeout 为空用传输的默认值；应用账号登录要等中转代登录教务，另给更长的。
  Future<Map<String, Object?>> request(SocialIdentity identity, String method, String path, [Map<String, Object?>? payload, Duration? timeout, int? limit]) => _call(identity, method, path, payload, timeout, false, limit);

  static int _integer(Object? value) => value is int ? value : throw const RelayException(RelayCode.badResponse);
  static String _text(Object? value) => value is String ? value : throw const RelayException(RelayCode.badResponse);
}
