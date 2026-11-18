import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/relay/relay_client.dart';
import 'package:superxd/relay/relay_crypto.dart';
import 'package:superxd/social/social_crypto.dart';

// 服务端好友列表里的一项：换了设备的好友 movedFrom 是本机认得的旧设备号，keys 是它的新公钥（已核对与设备号一致）。
class RemoteFriend {
  const RemoteFriend({required this.deviceId, required this.since, this.keys, this.movedFrom});
  final String deviceId;
  final int since;
  final PeerKeys? keys;
  final String? movedFrom;
}

class InboxItem {
  const InboxItem({required this.id, required this.from, required this.envelope, required this.createTime});
  final String id;
  final String from;
  final List<int> envelope;
  final int createTime;
}

// 私信经中转的那些接口（协议 v1，见 server/README.md）：签名、校时重发一次与「账号已注销」的核对都在 relay 层的 RelayClient，这里只管私信的路径与回复。
// serverKeys 是受信的服务器在线签名公钥（base64url），默认内置的；测试换成测试钥。
class SocialRelay {
  SocialRelay(RelayTransport transport, {List<String> serverKeys = relayServerKeys}) : _relay = RelayClient(transport, serverKeys: serverKeys);
  final RelayClient _relay;

  // 本机时钟与服务器的差（毫秒），二维码倒计时按它校正。
  int get clockOffset => _relay.clockOffset;

  // 拉信箱的响应上限按这次要的条数算：单条密文最多 256KB（服务端 relay_limits.ts 的 envelopeMaxBytes），经 base64url 约 342KB，
  // 加上消息号、发送方与时刻，每条按 360KB 算，再留普通接口那份余量（50 条约 18MB）。
  static int inboxLimit(int count) => count * 360 * 1024 + HttpRelayTransport.responseLimit;

  // 删除本设备：服务端删掉本设备的好友关系、待收消息与注册记录。
  Future<void> deleteDevice(RelayIdentity identity) => _relay.deleteDevice(identity);

  Future<int> createInvite(RelayIdentity identity, String inviteId, List<int> publicKey) async =>
      _integer((await _relay.request(identity, 'POST', '/v1/invites', payload: {'inviteId': inviteId, 'publicKey': base64UrlNoPad(publicKey)}))['expiresAt']);

  Future<void> revokeInvite(RelayIdentity identity, String inviteId) => _relay.request(identity, 'DELETE', '/v1/invites/$inviteId');

  Future<int> redeem(RelayIdentity identity, {required String inviteId, required List<int> proof, required String helloId, required List<int> hello}) async {
    final body = await _relay.request(identity, 'POST', '/v1/friends/redeem', payload: {
      'inviteId': inviteId,
      'proof': base64UrlNoPad(proof),
      'hello': {'clientId': helloId, 'envelope': base64UrlNoPad(hello)},
    });
    return _integer(body['since']);
  }

  // 服务端的好友列表（最多 500 个）。换了设备的好友带新公钥与 movedFrom（本机认得的旧设备号）；keys 为真时每个都带公钥（新手机接管后拿名单），
  // 这时响应放宽到 256KB（500 个好友各两把公钥约 120KB）。公钥与设备号对不上、没有服务器签名或验不过的当格式不对（见 relay_client.dart 的 relayServerKeys）。
  Future<Map<String, RemoteFriend>> friends(RelayIdentity identity, {bool keys = false}) async {
    final list = (await _relay.request(identity, 'GET', keys ? '/v1/friends?keys=1' : '/v1/friends', limit: keys ? 256 * 1024 : null))['friends'];
    if (list is! List) throw const RelayException(RelayCode.badResponse);
    final friends = <String, RemoteFriend>{};
    for (final item in list.cast<Map<Object?, Object?>>()) {
      final deviceId = _text(item['deviceId']);
      final movedFrom = switch (item['movedFrom']) {
        null => null,
        final String movedFrom => movedFrom,
        _ => throw const RelayException(RelayCode.badResponse),
      };
      friends[deviceId] = RemoteFriend(deviceId: deviceId, since: _integer(item['since']), keys: await _keys(item, identity.deviceId, deviceId, movedFrom), movedFrom: movedFrom);
    }
    return friends;
  }

  Future<PeerKeys?> _keys(Map<Object?, Object?> item, String ownerDeviceId, String deviceId, String? movedFrom) async {
    if (item['signPublicKey'] == null && item['boxPublicKey'] == null) return null;
    final signText = _text(item['signPublicKey']), boxText = _text(item['boxPublicKey']);
    final sign = tryDecodeBase64UrlNoPad(signText, length: 32), box = tryDecodeBase64UrlNoPad(boxText, length: 32), signature = tryDecodeBase64UrlNoPad(_text(item['keysSignature']), length: 64);
    if (sign == null || box == null || signature == null) throw const RelayException(RelayCode.badResponse);
    final keys = PeerKeys(sign, box);
    if (keys.deviceId != deviceId) throw const RelayException(RelayCode.badResponse);
    if (await verifyRelaySignature(_relay.serverKeys, friendKeysCanonical(ownerDeviceId, deviceId, signText, boxText, movedFrom), signature)) return keys;
    campusLog('[Relay] action=friend_keys errorType=signature deviceId=$deviceId');
    throw const RelayException(RelayCode.badResponse);
  }

  // 处理完这些好友换设备的提示（新设备号），服务端清掉 movedFrom。
  Future<void> ackMoves(RelayIdentity identity, List<String> deviceIds) => _relay.request(identity, 'POST', '/v1/friends/moves/ack', payload: {'deviceIds': deviceIds});

  // 把私信设备挂到应用账号（用应用账号的设备密钥 account 签名，请求体带私信密钥对两把钥匙的签名）；没注册过的私信设备顺带登记。
  // 账号的私信在另一台设备上时抛 SOCIAL_ELSEWHERE，takeover 为真时接管过来；返回这次是否从别的设备接管。
  Future<bool> bindSocial(RelayIdentity account, RelayIdentity social, {bool takeover = false}) async {
    final proof = await social.sign(socialBindCanonical(account.deviceId, social.deviceId));
    final body = await _relay.request(account, 'POST', '/v1/account/social', payload: {
      'signPublicKey': base64UrlNoPad(social.signPublicKey),
      'boxPublicKey': base64UrlNoPad(social.boxPublicKey),
      'proof': base64UrlNoPad(proof),
      if (takeover) 'takeover': true,
    });
    final moved = body['moved'];
    return body['deviceId'] == social.deviceId && moved is bool ? moved : throw const RelayException(RelayCode.badResponse);
  }

  Future<void> removeFriend(RelayIdentity identity, String peerDeviceId) => _relay.request(identity, 'DELETE', '/v1/friends/$peerDeviceId');

  Future<int> send(RelayIdentity identity, {required String to, required String clientId, required List<int> envelope}) async =>
      _integer((await _relay.request(identity, 'POST', '/v1/messages', payload: {'to': to, 'clientId': clientId, 'envelope': base64UrlNoPad(envelope)}))['createTime']);

  // wait 为长轮询挂起时长（服务端上限 25 秒）：没有消息时服务端挂起到有新消息或到时；本次请求超时放宽到挂起时长再加 10 秒。
  // 长轮询按后台请求发（background），断网与超时算不算错误交给收取循环。
  Future<({List<InboxItem> messages, bool more})> fetch(RelayIdentity identity, {String? after, int limit = 50, Duration? wait}) async {
    final query = '${after == null ? '' : 'after=$after&'}limit=$limit${wait == null ? '' : '&wait=${wait.inSeconds}'}';
    final body = await _relay.request(identity, 'GET', '/v1/messages?$query', timeout: wait == null ? null : wait + const Duration(seconds: 10), limit: inboxLimit(limit), background: wait != null);
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

  Future<void> ack(RelayIdentity identity, List<String> ids) => _relay.request(identity, 'POST', '/v1/messages/ack', payload: {'ids': ids});

  static int _integer(Object? value) => value is int ? value : throw const RelayException(RelayCode.badResponse);
  static String _text(Object? value) => value is String ? value : throw const RelayException(RelayCode.badResponse);
}
