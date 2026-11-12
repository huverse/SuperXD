import 'dart:async';
import 'dart:math';

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
// 联网时机：开启、出示/扫码、发送、刷新（回到前台、进入私信、下拉），以及前台长轮询收消息。除校时重发一次、中转不认这台设备时重新注册后重放一次（见 _authorized）外不自动重试。
class SocialService extends ChangeNotifier {
  SocialService({required this.store, required this.vault, RelayTransport? transport, DateTime Function()? clock, Random? random, this.polling = false})
    : _relay = transport == null ? null : RelayClient(transport),
      _clock = clock ?? DateTime.now,
      _random = random ?? Random();
  // 就绪后是否在前台持续长轮询收消息（应用里开启；测试关闭，避免残留请求与定时器）。
  final bool polling;
  // 长轮询每次挂起时长，服务端上限 25 秒。
  static const longPollWait = Duration(seconds: 25);
  final SocialStore store;
  final IdentityVault vault;
  final RelayClient? _relay;
  final DateTime Function() _clock;
  // 长轮询退避的随机抖动（见 liveRetryDelay）；测试注入固定的随机源。
  final Random _random;
  final _refreshLock = Lock();
  final _uuid = const Uuid();
  SocialIdentity? _identity;
  // 正在进行的重新注册（见 _authorized），几个请求同时遇到 UNAUTHORIZED 时共用这一次。
  Future<void>? _reregistering;
  AppLifecycleListener? _lifecycle;
  bool _foreground = true;
  bool _living = false;
  bool _disposed = false;

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

  // [人工决策-2026-11-11 23:16:31] 中转不认这台设备时自动重新注册一次并重放这一次请求（用户 11-11 要求按最佳实践补上 W1 报的缺口）：
  // 中转从旧备份恢复、或设备 400 天不活跃被清掉后，所有签名请求都回 UNAUTHORIZED，以前收不到、发不出，也关不掉私信。
  // 设备号由签名公钥推出、注册自签名且幂等，正常客户端只有中转没有这台设备时才会收到 UNAUTHORIZED，所以照「会话失效自动恢复一次再重放」的做法：
  // 只注册一次、只重放一次，重放后仍失败就照常报错；几个请求同时遇到时共用一次注册。没选「只标记未注册、等用户再点」：
  // 用户看到的会是一次说不清原因的失败。服务端那边的好友关系随设备一起没了，之后发送照常回 NOT_FRIEND 并标记对方已解除，要重新扫码。
  Future<T> _authorized<T>(Future<T> Function(RelayClient relay, SocialIdentity identity) call) async {
    final relay = _relay!, identity = _identity!;
    try {
      return await call(relay, identity);
    } on RelayException catch (error) {
      if (error.code != RelayCode.unauthorized) rethrow;
      campusLog('[Social] action=reregister deviceId=${identity.deviceId}');
      await (_reregistering ??= _register().whenComplete(() => _reregistering = null));
      return call(relay, identity);
    }
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
  // 中转已经不认这台设备（UNAUTHORIZED）时没有可删的，照样清本机（同节日抽奖身份的 retire）。
  Future<void> disable() async {
    final relay = _ready();
    try {
      await relay.deleteDevice(_identity!);
    } on RelayException catch (error) {
      if (error.code != RelayCode.unauthorized) throw SocialException(error.code);
      campusLog('[Social] action=disable state=not_registered');
    }
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
    _ready();
    final inviteSeed = randomBytes(32);
    final inviteId = base64UrlNoPad(randomBytes(16));
    final publicKey = await ed25519PublicOf(inviteSeed);
    final int expiresAt;
    try {
      expiresAt = await _authorized((relay, identity) => relay.createInvite(identity, inviteId, publicKey));
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
      await _authorized((relay, identity) => relay.redeem(identity, inviteId: code.inviteId, proof: proof, helloId: helloId, hello: hello));
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
        String? after;
        var received = 0;
        for (var page = 0; page < 20; page++) {
          final batch = await _authorized((relay, identity) => relay.fetch(identity, after: after));
          received += await _consume(batch.messages);
          if (batch.messages.isNotEmpty) after = batch.messages.last.id;
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

  // 处理一批信箱消息并确认删除，返回新增条数；调用方须持有 _refreshLock。
  Future<int> _consume(List<InboxItem> items) async {
    if (items.isEmpty) return 0;
    var received = 0;
    for (final item in items) {
      if (await _accept(item)) received++;
    }
    await _authorized((relay, identity) => relay.ack(identity, [for (final item in items) item.id]));
    return received;
  }

  // 服务端没有、本机还有效的好友，标为对方已解除。
  Future<void> _reconcile() async {
    final remote = await _authorized((relay, identity) => relay.friends(identity));
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
        await _authorized((relay, identity) => relay.send(identity, to: friend.deviceId, clientId: messageId, envelope: envelope));
      } on RelayException catch (relayError) {
        error = relayError.code;
        if (relayError.code == RelayCode.notFriend) await store.markRemoved(friend.deviceId);
      } catch (unexpected, stack) {
        campusLog('[Social] action=send errorType=${unexpected.runtimeType}\n$stack');
        error = RelayCode.badResponse;
      }
    }
    await store.setState(messageId, error == null ? MessageState.sent : MessageState.failed, error: error);
    // 发成功不带 errorType=：带了（哪怕是空的）就会被本机日志当成错误记下（11-09 日志里每次发成功都进了错误记录）。
    campusLog('[Social] action=send friendId=${message.friendId} ${error == null ? 'state=sent' : 'state=failed errorType=$error'}');
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
    _ready();
    try {
      await _authorized((relay, identity) => relay.removeFriend(identity, friendId));
    } on RelayException catch (error) {
      throw SocialException(error.code);
    }
    await store.deleteFriend(friendId);
    campusLog('[Social] action=remove_friend friendId=$friendId');
    await _reload();
  }

  // [人工决策-2026-10-04 22:10:46] 收消息用前台长轮询（不接厂商推送，后台收不到）：应用在前台且私信就绪时始终挂着一个拉取请求，
  // 有新消息服务端立即返回，接近实时；没有就 25 秒后空返回再挂。回到前台先拉一次并核对好友，进入后台不再发起（在途请求自然结束）。
  // 网络失败按 2、4、8…秒退避、上限 60 秒；空响应快于 5 秒（服务端满载时会立即返回）也等满 5 秒，防止空转。
  void startPolling() {
    _lifecycle ??= AppLifecycleListener(
      onResume: () {
        _foreground = true;
        _background(refresh(reconcile: true));
        _live();
      },
      onPause: () => _foreground = false,
    );
    _live();
  }

  bool get _keepLive => polling && _foreground && !_disposed && status == SocialStatus.ready;

  void _live() {
    if (_living || !_keepLive) return;
    _living = true;
    _background(_liveLoop());
  }

  // [人工决策-2026-11-09 19:18:09] 长轮询的断网与超时连续失败才算错误（用户选定）：单次是可恢复的网络抖动，只在开发者模式记一行、不进错误记录；
  // 连续失败到 liveFailureLimit 次记一条错误，同一段断网只记这一条，连上后重新计数。同 10-22「后台回收不算错误」，
  // Crashlytics 也不把可恢复的网络抖动算错误。起因：11-09 日志里这两类占错误记录约六成，每次两条、一条带完整堆栈，真错误被挤掉。
  static const liveFailureLimit = 5;

  // 长轮询失败这一次记哪一行：断网、超时没到连续上限只记一行不算错误的（不带 errorType=），正好到上限那次记错误；
  // 中转回的其他错误码只记错误码；其他异常记完整堆栈。
  static String liveFailureLog(Object error, StackTrace stack, {required int failures, required Duration retryIn}) => switch (error) {
    RelayException(:final code) when (code == RelayCode.network || code == RelayCode.timeout) && failures != liveFailureLimit =>
      '[Social] action=live state=retry code=$code failures=$failures retryIn=${retryIn.inSeconds}s',
    RelayException(:final code) => '[Social] action=live errorType=$code failures=$failures retryIn=${retryIn.inSeconds}s',
    _ => '[Social] action=live errorType=${error.runtimeType} retryIn=${retryIn.inSeconds}s\n$stack',
  };

  // [人工决策-2026-11-10 18:47:42] 长轮询失败的退避加随机抖动（用户确认 W7 工作包方向）：每档 2、4、8…秒、上限 60 秒不变，
  // 实际等待在这一档的一半到整档之间随机，中转重启或断网恢复时各客户端不再同拍重连。选「一半到整档」（equal jitter），
  // 没选「零到整档」（full jitter）：留住下限，失败后不会紧接着就再打一次。
  static Duration liveRetryDelay(Duration backoff, Random random) => backoff * (0.5 + random.nextDouble() / 2);

  Future<void> _liveLoop() async {
    var backoff = const Duration(seconds: 2);
    var failures = 0;
    try {
      while (_keepLive) {
        final started = _clock();
        try {
          final batch = await _authorized((relay, identity) => relay.fetch(identity, wait: longPollWait));
          if (!_keepLive) break;
          backoff = const Duration(seconds: 2);
          failures = 0;
          if (batch.messages.isNotEmpty) {
            final received = await _refreshLock.synchronized(() => _consume(batch.messages));
            campusLog('[Social] action=live received=$received');
            await _reload();
            continue;
          }
          final elapsed = _clock().difference(started);
          if (elapsed < const Duration(seconds: 5)) await Future<void>.delayed(const Duration(seconds: 5) - elapsed);
        } catch (error, stack) {
          // 都退避后继续，不让收消息在前台静默停掉。
          failures++;
          final delay = liveRetryDelay(backoff, _random);
          campusLog(liveFailureLog(error, stack, failures: failures, retryIn: delay));
          await Future<void>.delayed(delay);
          backoff = backoff * 2 > const Duration(seconds: 60) ? const Duration(seconds: 60) : backoff * 2;
        }
      }
    } finally {
      _living = false;
    }
  }

  void _background(Future<void> work) => work.catchError((Object error, StackTrace stack) {
    campusLog('[Social] action=background errorType=${error.runtimeType}\n$stack');
  });

  @override
  void dispose() {
    _disposed = true;
    _lifecycle?.dispose();
    super.dispose();
  }
}
