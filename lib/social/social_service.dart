import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/social/social_store.dart';

enum SocialStatus { loading, unavailable, disabled, ready, failed }

// 发送或加好友失败：code 是 RelayCode 或本地错误码（见 socialErrorText）。
class SocialException implements Exception {
  const SocialException(this.code);
  final String code;
  @override
  String toString() => 'SocialException($code)';
}

// 本地错误码（与 RelayCode 同一命名空间，界面按 code 给文案）。
abstract final class SocialCode {
  static const notReady = 'NOT_READY'; // 私信未开启
  static const inviteExpired = 'INVITE_EXPIRED'; // 二维码已过期（本机判定）
  static const notInvite = 'NOT_INVITE'; // 不是 SuperXD 好友二维码
  static const localFriendLimit = 'LOCAL_FRIEND_LIMIT'; // 本机好友已满
  static const friendRemoved = 'FRIEND_REMOVED'; // 对方已解除好友
  static const identityLost = 'IDENTITY_LOST'; // 安全存储里的身份丢失，需重新开启
}

// [人工决策-2026-10-04 16:44:36] 好友与私信的身份跟设备走（独立昵称、不暴露学号），切换教务账号保留，百宝箱未登录也能分享。
// 私信编排：本机库、设备身份与中转服务之间的唯一入口，页面只经它读写。设备级，切换教务账号保留。
// 联网时机：开启、出示/扫码、发送、刷新（回到前台、进入私信、下拉、前台每 60 秒）。除校时重发一次外不自动重试。
class SocialService extends ChangeNotifier {
  SocialService({required this.store, required this.vault, RelayTransport? transport, DateTime Function()? clock, this.polling = false})
    : _relay = transport == null ? null : RelayClient(transport),
      _clock = clock ?? DateTime.now;
  // 就绪后是否自动前台轮询（应用里开启；测试关闭，避免残留定时器）。
  final bool polling;
  final SocialStore store;
  final IdentityVault vault;
  final RelayClient? _relay;
  final DateTime Function() _clock;
  final _refreshLock = Lock();
  final _uuid = const Uuid();
  SocialIdentity? _identity;
  Timer? _poller;
  AppLifecycleListener? _lifecycle;

  SocialStatus status = SocialStatus.loading;
  SocialProfile? profile;
  List<SocialFriend> friends = const [];
  int unread = 0;
  bool refreshing = false;
  // 最近一次刷新的错误码，成功后清空；界面只在用户下拉刷新失败时提示。
  String? refreshError;
  String? get deviceId => _identity?.deviceId;
  // 按服务器校正过的当前时刻（毫秒），用于二维码倒计时。
  int get serverNow => _clock().millisecondsSinceEpoch + (_relay?.clockOffset ?? 0);

  String _now() => _clock().toUtc().toIso8601String();

  Future<void> initialize() async {
    try {
      if (_relay == null) {
        status = SocialStatus.unavailable;
        return;
      }
      profile = await store.profile();
      if (profile == null) {
        status = SocialStatus.disabled;
        return;
      }
      _identity = await vault.read();
      if (_identity == null) {
        // 本机库还在但身份没了（清除了安全存储）：旧好友的消息已无法解密，回到未开启。
        campusLog('[Social] action=initialize errorType=${SocialCode.identityLost}');
        await store.clear();
        profile = null;
        status = SocialStatus.disabled;
        return;
      }
      await store.failInterrupted();
      await store.pruneInvites(_clock().toUtc().subtract(inviteRetention).toIso8601String());
      if (!profile!.registered) await _register();
      _becomeReady();
      await _reload();
    } catch (error, stack) {
      campusLog('[Social] action=initialize errorType=${error.runtimeType}\n$stack');
      status = SocialStatus.failed;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _register() async {
    await _relay!.register(_identity!);
    profile = SocialProfile(nickname: profile!.nickname, registered: true);
    await store.saveProfile(profile!);
  }

  Future<void> _reload() async {
    friends = await store.friends();
    unread = await store.unreadTotal();
    notifyListeners();
  }

  void _becomeReady() {
    status = SocialStatus.ready;
    if (polling) startPolling();
  }

  RelayClient _ready() {
    if (status != SocialStatus.ready || _identity == null) throw const SocialException(SocialCode.notReady);
    return _relay!;
  }

  // 开启私信：生成设备身份、注册到中转服务、保存昵称。注册失败时身份与昵称已保存，下次启动或再点开启时补注册。
  Future<void> enable(String nickname) async {
    if (_relay == null) throw const SocialException(SocialCode.notReady);
    if (!validNickname(nickname)) throw ArgumentError.value(nickname, 'nickname');
    _identity ??= await vault.read() ?? await () async {
      final created = await SocialIdentity.generate();
      await vault.write(created);
      return created;
    }();
    profile = SocialProfile(nickname: nickname, registered: false);
    await store.saveProfile(profile!);
    try {
      await _register();
    } on RelayException catch (error) {
      notifyListeners();
      throw SocialException(error.code);
    }
    _becomeReady();
    campusLog('[Social] action=enable deviceId=${_identity!.deviceId}');
    await _reload();
  }

  // 只改本机昵称：之后出示的二维码与问候带新昵称，已加的好友那边不变。
  Future<void> rename(String nickname) async {
    if (!validNickname(nickname)) throw ArgumentError.value(nickname, 'nickname');
    profile = SocialProfile(nickname: nickname, registered: profile!.registered);
    await store.saveProfile(profile!);
    notifyListeners();
  }

  // 关闭私信：先请中转服务删除本设备（好友关系与待收消息），再清空本机数据与身份。服务端删除失败则不清本机，提示重试。
  Future<void> disable() async {
    final relay = _ready();
    try {
      await relay.deleteDevice(_identity!);
    } on RelayException catch (error) {
      throw SocialException(error.code);
    }
    stopPolling();
    await store.clear();
    await vault.delete();
    _identity = null;
    profile = null;
    friends = const [];
    unread = 0;
    status = SocialStatus.disabled;
    campusLog('[Social] action=disable');
    notifyListeners();
  }

  // 出示二维码：新建一次性邀请（服务端同时作废本设备之前的邀请），本机记下邀请公钥用于核验扫码方的问候。
  Future<InviteCode> createInvite() async {
    final relay = _ready();
    final inviteSeed = randomBytes(32);
    final inviteId = base64UrlNoPad(randomBytes(16));
    final publicKey = await ed25519PublicOf(inviteSeed);
    final int expiresAt;
    try {
      expiresAt = await relay.createInvite(_identity!, inviteId, publicKey);
    } on RelayException catch (error) {
      throw SocialException(error.code);
    }
    await store.saveInvite(inviteId, base64UrlNoPad(publicKey), _now());
    return InviteCode(inviteId: inviteId, inviteSeed: inviteSeed, owner: PeerKeys(_identity!.signPublicKey, _identity!.boxPublicKey), nickname: profile!.nickname, expiresAt: expiresAt);
  }

  // 离开二维码页即作废，不让截图在有效期内继续被扫。失败只记日志：5 分钟后自然过期。
  Future<void> revokeInvite(String inviteId) async {
    try {
      await _ready().revokeInvite(_identity!, inviteId);
    } catch (error, stack) {
      campusLog('[Social] action=revoke_invite errorType=${error.runtimeType}\n$stack');
    }
  }

  // [人工决策-2026-10-04 16:44:36] 扫码即成为好友（出示二维码视为同意），不做申请确认；二维码 5 分钟有效、期内可被多人扫。
  // 扫码：用邀请私钥签凭证，连同给对方的问候（自己的公钥与昵称，端到端加密）一起提交；成功后本机加对方为好友。
  Future<SocialFriend> redeem(InviteCode code) async {
    final relay = _ready();
    final identity = _identity!;
    if (code.owner.deviceId == identity.deviceId) throw const SocialException(RelayCode.inviteSelf);
    if (code.expiresAt < _clock().millisecondsSinceEpoch + relay.clockOffset) throw const SocialException(SocialCode.inviteExpired);
    final existing = await store.friend(code.owner.deviceId);
    if (existing == null && await store.friendCount() >= friendLimit) throw const SocialException(SocialCode.localFriendLimit);
    final helloId = _uuid.v4();
    final proof = await signWithSeed(code.inviteSeed, inviteProofCanonical(code.inviteId, identity.deviceId));
    final hello = await sealEnvelope(sender: identity, recipient: code.owner, message: {
      'v': 1,
      'id': helloId,
      'from': identity.deviceId,
      'to': code.owner.deviceId,
      'sentAt': _clock().millisecondsSinceEpoch,
      'kind': 'hello',
      'hello': {
        'nickname': profile!.nickname,
        'signPublicKey': base64UrlNoPad(identity.signPublicKey),
        'boxPublicKey': base64UrlNoPad(identity.boxPublicKey),
        'inviteId': code.inviteId,
        'proof': base64UrlNoPad(proof),
      },
    });
    try {
      await relay.redeem(identity, inviteId: code.inviteId, proof: proof, helloId: helloId, hello: hello);
    } on RelayException catch (error) {
      throw SocialException(error.code);
    }
    await store.upsertFriend(deviceId: code.owner.deviceId, nickname: code.nickname, signPublicKey: base64UrlNoPad(code.owner.signPublicKey), boxPublicKey: base64UrlNoPad(code.owner.boxPublicKey), now: _now(), systemId: _uuid.v4());
    campusLog('[Social] action=redeem friendId=${code.owner.deviceId}');
    await _reload();
    return (await store.friend(code.owner.deviceId))!;
  }

  // 拉取信箱：解密、验签、入库后再确认删除；单次最多 20 页（1000 条），剩下的下次刷新继续。并发调用合并为一次。
  // reconcile 为真时顺带核对好友列表，标记已被对方解除的好友。
  Future<void> refresh({bool reconcile = false}) {
    if (status != SocialStatus.ready) return Future.value();
    return _refreshLock.synchronized(() async {
      refreshing = true;
      notifyListeners();
      try {
        final relay = _relay!, identity = _identity!;
        String? after;
        var received = 0;
        for (var page = 0; page < 20; page++) {
          final batch = await relay.fetch(identity, after: after);
          for (final item in batch.messages) {
            if (await _accept(item)) received++;
          }
          if (batch.messages.isNotEmpty) {
            await relay.ack(identity, [for (final item in batch.messages) item.id]);
            after = batch.messages.last.id;
          }
          if (!batch.more) break;
        }
        if (reconcile) await _reconcile();
        refreshError = null;
        campusLog('[Social] action=refresh received=$received');
      } on RelayException catch (error) {
        refreshError = error.code;
        campusLog('[Social] action=refresh errorType=${error.code}');
      } catch (error, stack) {
        refreshError = RelayCode.badResponse;
        campusLog('[Social] action=refresh errorType=${error.runtimeType}\n$stack');
      } finally {
        refreshing = false;
        await _reload();
      }
    });
  }

  // 服务端没有、本机还有效的好友，标为对方已解除。
  Future<void> _reconcile() async {
    final remote = await _relay!.friends(_identity!);
    for (final friend in await store.friends()) {
      if (!friend.removed && !remote.containsKey(friend.deviceId)) await store.markRemoved(friend.deviceId);
    }
  }

  // 处理一条信箱消息，返回是否新增了内容。任何不合格的消息都丢弃并记日志（照样确认删除，避免反复拉取同一条坏消息）。
  Future<bool> _accept(InboxItem item) async {
    final identity = _identity!;
    try {
      final opened = await openEnvelope(recipient: identity, envelope: item.envelope);
      final message = opened.message;
      final id = message['id'];
      if (message['v'] != 1 || id is! String || !RegExp(r'^[0-9a-f-]{36}$').hasMatch(id) || message['from'] != item.from || message['to'] != identity.deviceId) {
        throw const SocialCryptoException('消息头不符');
      }
      final now = DateTime.fromMillisecondsSinceEpoch(item.createTime, isUtc: true).toIso8601String();
      switch (message['kind']) {
        case 'hello':
          return await _acceptHello(item.from, message['hello'], opened, id, now);
        case 'card':
          final friend = await store.friend(item.from);
          if (friend == null) throw const SocialCryptoException('非好友消息');
          if (!await verifyOpened(opened, decodeBase64UrlNoPad(friend.signPublicKey, length: 32))) throw const SocialCryptoException('签名无效');
          return await store.addCard(id: id, friendId: item.from, outgoing: false, state: MessageState.received, card: decodeShareCard(message['card']), now: now);
        default:
          throw const SocialCryptoException('未知消息类型');
      }
    } catch (error, stack) {
      campusLog('[Social] action=accept errorType=${error.runtimeType} from=${item.from}\n$stack');
      return false;
    }
  }

  // 问候：扫码方的公钥由凭证担保——凭证须由本机出示过的邀请私钥签出、且绑定扫码方设备号，服务器无法伪造。
  Future<bool> _acceptHello(String from, Object? json, OpenedEnvelope opened, String id, String now) async {
    if (json is! Map) throw const SocialCryptoException('问候格式不正确');
    final hello = json.cast<String, Object?>();
    final nickname = hello['nickname'], inviteId = hello['inviteId'];
    if (nickname is! String || !validNickname(nickname) || inviteId is! String) throw const SocialCryptoException('问候格式不正确');
    final keys = PeerKeys(decodeBase64UrlNoPad(hello['signPublicKey'] as String, length: 32), decodeBase64UrlNoPad(hello['boxPublicKey'] as String, length: 32));
    if (keys.deviceId != from || !await verifyOpened(opened, keys.signPublicKey)) throw const SocialCryptoException('问候签名无效');
    final invitePublic = await store.invitePublicKey(inviteId);
    if (invitePublic == null) throw const SocialCryptoException('邀请不存在');
    final proof = decodeBase64UrlNoPad(hello['proof'] as String, length: 64);
    if (!await verifySignature(decodeBase64UrlNoPad(invitePublic, length: 32), inviteProofCanonical(inviteId, from), proof)) throw const SocialCryptoException('邀请凭证无效');
    if (await store.friend(from) == null && await store.friendCount() >= friendLimit) throw const SocialCryptoException('本机好友已满');
    await store.upsertFriend(deviceId: from, nickname: nickname, signPublicKey: base64UrlNoPad(keys.signPublicKey), boxPublicKey: base64UrlNoPad(keys.boxPublicKey), now: now, systemId: id);
    return true;
  }

  // 发送卡片：先在本机记为“发送中”（界面原地显示），再加密投递；失败记错误码，由用户点重发（同一消息号，服务端幂等）。
  Future<SocialMessage> send(String friendId, ShareCard card) async {
    _ready();
    final id = _uuid.v4();
    await store.addCard(id: id, friendId: friendId, outgoing: true, state: MessageState.sending, card: card, now: _now());
    await _reload();
    return _deliver(id);
  }

  Future<SocialMessage> retry(String messageId) async {
    _ready();
    await store.setState(messageId, MessageState.sending);
    notifyListeners();
    return _deliver(messageId);
  }

  Future<SocialMessage> _deliver(String messageId) async {
    final message = (await store.message(messageId))!;
    final friend = await store.friend(message.friendId);
    String? error;
    if (friend == null || friend.removed) {
      error = SocialCode.friendRemoved;
    } else {
      try {
        final identity = _identity!;
        final envelope = await sealEnvelope(
          sender: identity,
          recipient: PeerKeys(decodeBase64UrlNoPad(friend.signPublicKey, length: 32), decodeBase64UrlNoPad(friend.boxPublicKey, length: 32)),
          message: {'v': 1, 'id': messageId, 'from': identity.deviceId, 'to': friend.deviceId, 'sentAt': _clock().millisecondsSinceEpoch, 'kind': 'card', 'card': encodeShareCard(message.card!)},
        );
        await _relay!.send(identity, to: friend.deviceId, clientId: messageId, envelope: envelope);
      } on RelayException catch (relayError) {
        error = relayError.code;
        if (relayError.code == RelayCode.notFriend) await store.markRemoved(friend.deviceId);
      } catch (unexpected, stack) {
        campusLog('[Social] action=send errorType=${unexpected.runtimeType}\n$stack');
        error = RelayCode.badResponse;
      }
    }
    await store.setState(messageId, error == null ? MessageState.sent : MessageState.failed, error: error);
    campusLog('[Social] action=send friendId=${message.friendId} state=${error == null ? 'sent' : 'failed'} errorType=${error ?? ''}');
    await _reload();
    return (await store.message(messageId))!;
  }

  Future<List<SocialMessage>> conversation(String friendId) => store.conversation(friendId);

  Future<void> markRead(String friendId) async {
    await store.markRead(friendId);
    await _reload();
  }

  Future<void> setRemark(String friendId, String? remark) async {
    await store.setRemark(friendId, remark == null || remark.trim().isEmpty ? null : remark.trim());
    await _reload();
  }

  Future<void> deleteMessage(String messageId) async {
    await store.deleteMessage(messageId);
    await _reload();
  }

  // 删除好友：服务端双向解除（对方之后发来的被拒收），本机删除会话。对方已解除时服务端无关系可删，直接删本机。
  Future<void> removeFriend(String friendId) async {
    final relay = _ready();
    try {
      await relay.removeFriend(_identity!, friendId);
    } on RelayException catch (error) {
      throw SocialException(error.code);
    }
    await store.deleteFriend(friendId);
    campusLog('[Social] action=remove_friend friendId=$friendId');
    await _reload();
  }

  // 前台轮询：回到前台立即刷新，前台每 60 秒刷新一次；进入后台停止。没有推送通道（国内无统一推送），这是收消息的唯一方式。
  void startPolling() {
    _lifecycle ??= AppLifecycleListener(
      onResume: () {
        _schedule();
        _background(refresh(reconcile: true));
      },
      onPause: () => _poller?.cancel(),
    );
    _schedule();
  }

  void _schedule() {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(seconds: 60), (_) => _background(refresh()));
  }

  void _background(Future<void> work) => work.catchError((Object error, StackTrace stack) {
    campusLog('[Social] action=poll errorType=${error.runtimeType}\n$stack');
  });

  void stopPolling() {
    _poller?.cancel();
    _poller = null;
  }

  @override
  void dispose() {
    stopPolling();
    _lifecycle?.dispose();
    super.dispose();
  }
}
