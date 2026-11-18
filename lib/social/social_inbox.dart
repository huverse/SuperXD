import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/relay/relay_crypto.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/social/social_store.dart';

// 私信的信（线上信箱与面对面共用，只在这里一份）：明文怎么写、收到后怎么核对与入库。

final _messageId = RegExp(r'^[0-9a-f-]{36}$');

Map<String, Object?> cardMessage({required String id, required String from, required String to, required int sentAt, required ShareCard card}) =>
    {'v': 1, 'id': id, 'from': from, 'to': to, 'sentAt': sentAt, 'kind': 'card', 'card': encodeShareCard(card)};

Map<String, Object?> profileMessage({required String id, required String from, required String to, required int sentAt, required String nickname}) =>
    {'v': 1, 'id': id, 'from': from, 'to': to, 'sentAt': sentAt, 'kind': 'profile', 'profile': {'nickname': nickname}};

// 扫码方给出示方的问候：自己的公钥与昵称，加上用邀请私钥签的凭证（只对自己的设备号有效）。
Map<String, Object?> helloMessage({required String id, required RelayIdentity identity, required String to, required int sentAt, required String nickname, required String inviteId, required List<int> proof}) => {
  'v': 1,
  'id': id,
  'from': identity.deviceId,
  'to': to,
  'sentAt': sentAt,
  'kind': 'hello',
  'hello': {
    'nickname': nickname,
    'signPublicKey': base64UrlNoPad(identity.signPublicKey),
    'boxPublicKey': base64UrlNoPad(identity.boxPublicKey),
    'inviteId': inviteId,
    'proof': base64UrlNoPad(proof),
  },
};

// 收下一封信，返回是否新增了内容；不合格抛异常（解不开、消息头不符、验签不过、卡片坏了），由调用方记日志并丢弃。
// relayFrom 是中转核实过的发件设备号；面对面没有中转、为空，只认信里签过名的 from：卡片与资料按本机好友的公钥验签，问候按信里的公钥与邀请凭证。
Future<bool> acceptEnvelope({required SocialStore store, required RelayIdentity identity, required List<int> envelope, required String? relayFrom, required String now}) async {
  final opened = await openEnvelope(recipient: identity, envelope: envelope);
  final message = opened.message;
  final id = message['id'], from = message['from'];
  if (message['v'] != 1 || id is! String || !_messageId.hasMatch(id) || from is! String || (relayFrom != null && from != relayFrom) || message['to'] != identity.deviceId) {
    throw const SocialCryptoException('消息头不符');
  }
  switch (message['kind']) {
    case 'hello':
      return _acceptHello(store, from, message['hello'], opened, id, now);
    case 'card':
      await _verifiedFriend(store, from, opened);
      return store.addCard(id: id, friendId: from, outgoing: false, state: MessageState.received, card: decodeShareCard(message['card']), now: now);
    case 'profile':
      await _verifiedFriend(store, from, opened);
      final nickname = switch (message['profile']) {
        {'nickname': final String nickname} when validNickname(nickname) => nickname,
        _ => throw const SocialCryptoException('资料格式不正确'),
      };
      await store.setNickname(from, nickname);
      return false;
    default:
      throw const SocialCryptoException('未知消息类型');
  }
}

// 卡片与资料只收好友发来、按好友公钥验签过的。
Future<void> _verifiedFriend(SocialStore store, String from, OpenedEnvelope opened) async {
  final friend = await store.friend(from);
  if (friend == null) throw const SocialCryptoException('非好友消息');
  if (!await verifyOpened(opened, decodeBase64UrlNoPad(friend.signPublicKey, length: 32))) throw const SocialCryptoException('签名无效');
}

// 问候：扫码方的公钥由凭证担保——凭证须由本机出示过的邀请私钥签出、且绑定扫码方设备号，服务器无法伪造。
Future<bool> _acceptHello(SocialStore store, String from, Object? json, OpenedEnvelope opened, String id, String now) async {
  if (json is! Map) throw const SocialCryptoException('问候格式不正确');
  final hello = json.cast<String, Object?>();
  final nickname = hello['nickname'], inviteId = hello['inviteId'];
  if (nickname is! String || !validNickname(nickname) || inviteId is! String) throw const SocialCryptoException('问候格式不正确');
  final keys = PeerKeys(decodeBase64UrlNoPad(hello['signPublicKey'] as String, length: 32), decodeBase64UrlNoPad(hello['boxPublicKey'] as String, length: 32));
  if (keys.deviceId != from || !await verifyOpened(opened, keys.signPublicKey)) throw const SocialCryptoException('问候签名无效');
  final invitePublic = await store.invitePublicKey(inviteId);
  if (invitePublic == null) throw const SocialCryptoException('邀请不存在');
  final proof = decodeBase64UrlNoPad(hello['proof'] as String, length: 64);
  if (!await verifyEd25519(decodeBase64UrlNoPad(invitePublic, length: 32), inviteProofCanonical(inviteId, from), proof)) throw const SocialCryptoException('邀请凭证无效');
  if (await store.friend(from) == null && await store.friendCount() >= friendLimit) throw const SocialCryptoException('本机好友已满');
  await store.upsertFriend(deviceId: from, nickname: nickname, signPublicKey: base64UrlNoPad(keys.signPublicKey), boxPublicKey: base64UrlNoPad(keys.boxPublicKey), now: now, systemId: id);
  return true;
}
