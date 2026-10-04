import 'dart:async';
import 'dart:convert';

import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';

// 内存版中转服务：按协议 v1 与服务端同样的规则验签、管理邀请、好友与信箱，供客户端编排测试使用。
// 真实服务端的行为由 server/test 的 e2e 覆盖；两边共用 server/test/vectors 下的测试向量。
class FakeRelay {
  final devices = <String, ({List<int> sign, List<int> box})>{};
  final invites = <String, ({String owner, List<int> publicKey, int expiresAt})>{};
  final friendships = <String>{};
  final mailbox = <({int id, String recipient, String sender, String clientId, List<int> envelope, int createTime})>[];
  final _nonces = <String>{};
  int _nextId = 0;
  // 服务器时间相对本机的偏差，模拟设备时钟不准。
  int serverOffset = 0;
  // 下一个请求直接抛出这个错误（模拟断网等）。
  RelayException? failNext;
  final calls = <String>[];
  // 长轮询中挂起的请求：设备号 → 等待者，投递时唤醒。
  final _waiters = <String, List<Completer<void>>>{};

  int get now => DateTime.now().millisecondsSinceEpoch + serverOffset;

  RelayTransport transport() => _FakeTransport(this);

  bool friends(String first, String second) => friendships.contains('$first|$second');

  // 测试结束时放掉还挂着的长轮询，不留未完成的计时。
  void releaseWaiters() {
    for (final waiter in _waiters.values.expand((list) => list)) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  Future<RelayResponse> handle(String method, String path, Map<String, String> headers, List<int>? body, {Duration? timeout}) async {
    calls.add('$method ${path.split('?').first}');
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw failure;
    }
    final payload = body == null ? <String, Object?>{} : (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();
    final deviceId = headers['x-sxd-device']!, time = headers['x-sxd-time']!, nonce = headers['x-sxd-nonce']!;
    if ((int.parse(time) - now).abs() > 5 * 60 * 1000) return _error(401, RelayCode.clockSkew, {'serverTime': now});
    final selfSigned = method == 'POST' && path == '/v1/devices';
    final signKey = selfSigned ? decodeBase64UrlNoPad(payload['signPublicKey'] as String) : devices[deviceId]?.sign;
    if (signKey == null) return _error(401, RelayCode.unauthorized);
    if (selfSigned && deviceIdOf(signKey) != deviceId) return _error(400, RelayCode.deviceMismatch);
    final canonical = requestCanonical(method, path, time, nonce, body ?? const []);
    if (!await verifySignature(signKey, canonical, decodeBase64UrlNoPad(headers['x-sxd-signature']!))) return _error(401, RelayCode.unauthorized);
    if (!_nonces.add('$deviceId:$nonce')) return _error(401, RelayCode.replayed);
    final uri = Uri.parse(path);
    switch ((method, uri.path)) {
      case ('POST', '/v1/devices'):
        devices[deviceId] = (sign: signKey, box: decodeBase64UrlNoPad(payload['boxPublicKey'] as String));
        return RelayResponse(200, {'deviceId': deviceId, 'serverTime': now});
      case ('DELETE', '/v1/devices'):
        devices.remove(deviceId);
        friendships.removeWhere((pair) => pair.split('|').contains(deviceId));
        mailbox.removeWhere((item) => item.recipient == deviceId);
        return const RelayResponse(204, {});
      case ('POST', '/v1/invites'):
        invites.removeWhere((_, invite) => invite.owner == deviceId);
        final expiresAt = now + 5 * 60 * 1000;
        invites[payload['inviteId'] as String] = (owner: deviceId, publicKey: decodeBase64UrlNoPad(payload['publicKey'] as String), expiresAt: expiresAt);
        return RelayResponse(200, {'inviteId': payload['inviteId'], 'expiresAt': expiresAt});
      case ('POST', '/v1/friends/redeem'):
        final inviteId = payload['inviteId'] as String;
        final invite = invites[inviteId];
        if (invite == null || invite.expiresAt < now) return _error(404, RelayCode.inviteNotFound);
        if (invite.owner == deviceId) return _error(400, RelayCode.inviteSelf);
        if (!await verifySignature(invite.publicKey, inviteProofCanonical(inviteId, deviceId), decodeBase64UrlNoPad(payload['proof'] as String))) {
          return _error(403, RelayCode.inviteProofInvalid);
        }
        friendships..add('$deviceId|${invite.owner}')..add('${invite.owner}|$deviceId');
        final hello = (payload['hello'] as Map).cast<String, Object?>();
        _deliver(invite.owner, deviceId, hello['clientId'] as String, decodeBase64UrlNoPad(hello['envelope'] as String));
        return RelayResponse(200, {'deviceId': invite.owner, 'since': now});
      case ('GET', '/v1/friends'):
        return RelayResponse(200, {
          'friends': [
            for (final pair in friendships)
              if (pair.startsWith('$deviceId|')) {'deviceId': pair.split('|')[1], 'since': now},
          ],
        });
      case ('POST', '/v1/messages'):
        final to = payload['to'] as String;
        if (!friends(deviceId, to)) return _error(403, RelayCode.notFriend);
        final envelope = decodeBase64UrlNoPad(payload['envelope'] as String);
        if (envelope.length > 256 * 1024) return _error(413, RelayCode.envelopeTooLarge);
        final stored = _deliver(to, deviceId, payload['clientId'] as String, envelope);
        return RelayResponse(200, {'id': '${stored.id}', 'createTime': stored.createTime});
      case ('GET', '/v1/messages'):
        final after = int.parse(uri.queryParameters['after'] ?? '0'), limit = int.parse(uri.queryParameters['limit'] ?? '50');
        final wait = int.parse(uri.queryParameters['wait'] ?? '0');
        if (wait > 0 && !mailbox.any((item) => item.recipient == deviceId && item.id > after)) {
          final waiter = Completer<void>();
          _waiters.putIfAbsent(deviceId, () => []).add(waiter);
          await waiter.future.timeout(Duration(seconds: wait), onTimeout: () {});
          _waiters[deviceId]?.remove(waiter);
        }
        final pending = mailbox.where((item) => item.recipient == deviceId && item.id > after).toList();
        return RelayResponse(200, {
          'messages': [
            for (final item in pending.take(limit)) {'id': '${item.id}', 'from': item.sender, 'envelope': base64UrlNoPad(item.envelope), 'createTime': item.createTime},
          ],
          'more': pending.length > limit,
        });
      case ('POST', '/v1/messages/ack'):
        final ids = (payload['ids'] as List).cast<String>().map(int.parse).toSet();
        mailbox.removeWhere((item) => item.recipient == deviceId && ids.contains(item.id));
        return const RelayResponse(200, {'removed': 0});
      case ('DELETE', final route) when route.startsWith('/v1/friends/'):
        final peer = route.substring('/v1/friends/'.length);
        friendships..remove('$deviceId|$peer')..remove('$peer|$deviceId');
        return const RelayResponse(204, {});
      case ('DELETE', final route) when route.startsWith('/v1/invites/'):
        invites.remove(route.substring('/v1/invites/'.length));
        return const RelayResponse(204, {});
    }
    return _error(404, RelayCode.invalidRequest);
  }

  ({int id, int createTime}) _deliver(String recipient, String sender, String clientId, List<int> envelope) {
    final existing = mailbox.where((item) => item.sender == sender && item.clientId == clientId).firstOrNull;
    if (existing != null) return (id: existing.id, createTime: existing.createTime);
    final stored = (id: ++_nextId, recipient: recipient, sender: sender, clientId: clientId, envelope: envelope, createTime: now);
    mailbox.add(stored);
    for (final waiter in [...?_waiters[recipient]]) {
      if (!waiter.isCompleted) waiter.complete();
    }
    return (id: stored.id, createTime: stored.createTime);
  }

  RelayResponse _error(int status, String code, [Map<String, Object?> extra = const {}]) => RelayResponse(status, {'code': code, 'message': code, ...extra});
}

class _FakeTransport implements RelayTransport {
  _FakeTransport(this.relay);
  final FakeRelay relay;
  @override
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout}) => relay.handle(method, pathWithQuery, headers, body, timeout: timeout);
}
