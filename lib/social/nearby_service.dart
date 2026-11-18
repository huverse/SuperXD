import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/nearby_radio.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/relay/relay_crypto.dart';
import 'package:superxd/social/friend_messaging.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/nearby_protocol.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/social/social_inbox.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_store.dart';

// loading：还没读本机；setup：还没设昵称（第一次用）；ready：可以用。
enum NearbyStatus { loading, setup, ready }

// [人工决策-2026-11-18 18:59:43] 面对面私信（任务书第 5 项最后一块，用户四项都选推荐）：
// - 只走蓝牙低功耗，双方都开着面对面页时互相发现、点好友就发，离开面对面页（或应用退到后台）就停；不做后台接收（安卓要常驻通知、iPhone 后台蓝牙不稳）。
// - 能发线上私信的全部卡片（课表、视频；视频卡只是链接）。
// - 不用登录应用账号、仅本机时也能用：用这台手机自己的身份（安全存储 superxd_social 的 nearby 一项），面对面扫码加「面对面好友」，库是 social/nearby.db（同私信一起排除备份）。
// - 登录应用账号后问一次要不要把面对面好友并进这个账号：并进的只在登录这个账号时看得到（换账号不串，收发都按 SocialStore 的范围），之后在这个账号下加的也归它；
//   不并的仍是这台手机自己的、谁登录都看得到；仍只走蓝牙，要变成线上好友照旧扫码加；注销应用账号时删掉并进它的。
// - 安卓 11 只在打开面对面页时申请位置权限（系统规定蓝牙扫描要它），安卓 12 起声明不用于定位、不要位置权限（device/ble_nearby_radio.dart）。
// 信与线上私信同一种加密（social_crypto.dart 的信封，端到端、发件人签名）、同一套收下规则（social_inbox.dart）；蓝牙上只多了出现标记（nearby_protocol.dart）。
// 不自动重试：没送到记错误码，用户点重发。
class NearbyService extends ChangeNotifier implements FriendMessaging {
  NearbyService({required this.radio, required this.vault, required this.openStore, DateTime Function()? clock, this.watchLifecycle = true}) : _clock = clock ?? DateTime.now;

  static const identityKey = 'nearby';
  // 二维码有效期，同线上；出示方只认这么久以内出示过的二维码（对方手机的钟差一点也照样认）。
  static const inviteLife = Duration(minutes: 5);
  // 扫了码之后在附近找出示的那台最多等多久。
  static const findTimeout = Duration(seconds: 20);

  final NearbyRadio radio;
  final IdentityVault vault;
  // 打开本机库 social/nearby.db（组合根给）。
  final Future<SocialStore> Function() openStore;
  final DateTime Function() _clock;
  // 应用退到后台时停蓝牙（测试关掉）。
  final bool watchLifecycle;
  final _uuid = const Uuid();
  final _openLock = Lock();
  SocialStore? _store;
  RelayIdentity? _identity;
  String? _account;
  bool _accountKnown = false;
  StreamSubscription<void>? _radioChanges;
  AppLifecycleListener? _lifecycle;
  int _users = 0;
  bool _foreground = true;
  ({String id, Uint8List seed})? _invite;
  Uint8List _presence = Uint8List(0);
  Map<String, Uint8List> _keys = const {};

  NearbyStatus status = NearbyStatus.loading;
  @override
  SocialProfile? profile;
  @override
  List<SocialFriend> friends = const [];
  // 此刻在附近的好友：设备号到这一次的蓝牙连接标识。
  Map<String, String> present = const {};

  NearbyRadioState get radioState => radio.state;
  String? get account => _account;

  @override
  int get serverNow => _clock().millisecondsSinceEpoch;

  String _now() => _clock().toUtc().toIso8601String();

  // ---------- 本机 ----------

  // 第一次用时读本机（页面打开时调）；身份丢了（安全存储被清）就清空本机面对面数据回到设昵称。
  Future<void> open() => _openLock.synchronized(() async {
    if (_store != null) return;
    final store = await openStore();
    await _scope(store);
    _identity = await vault.read(identityKey);
    profile = await store.profile();
    if (profile != null && _identity == null) {
      campusLog('[Nearby] action=identity_lost');
      await store.clear();
      profile = null;
    }
    await store.failInterrupted();
    await store.pruneInvites(_now());
    _store = store;
    status = profile == null ? NearbyStatus.setup : NearbyStatus.ready;
    _rebuildPresence();
    await _reload();
  });

  // 当前应用账号变了（组合根跟着应用账号调；没登录为空）：换读取范围，进行中的面对面照常。
  Future<void> setAccount(String? account) => _openLock.synchronized(() async {
    if (_accountKnown && account == _account) return;
    _account = account;
    _accountKnown = true;
    final store = _store;
    if (store == null) return;
    await _scope(store);
    await _reload();
  });

  Future<void> _scope(SocialStore store) async {
    final account = _account;
    store.scopeTo(FriendScope(account: account, merged: account != null && await store.ownerChoice(account) == true));
  }

  // 登录着应用账号、还没问过、这台手机上有自己的面对面好友时，要问几位（页面打开时问一次）；不用问为空。
  Future<int?> pendingMerge() async {
    final store = _store, account = _account;
    if (store == null || account == null || await store.ownerChoice(account) != null) return null;
    final count = await store.unownedCount();
    return count == 0 ? null : count;
  }

  Future<void> chooseMerge({required bool merge}) async {
    final store = _store!, account = _account!;
    await store.chooseOwner(account, merge: merge);
    await _scope(store);
    campusLog('[Nearby] action=choose_merge merge=$merge');
    await _reload();
  }

  // 应用账号注销了：删掉并进它的面对面好友（组合根在注销后调）。
  Future<void> forgetAccount(String account) async {
    await open();
    await _store!.forgetOwner(account);
    campusLog('[Nearby] action=forget_account');
    await _reload();
  }

  Future<void> enable(String nickname) async {
    if (!validNickname(nickname)) throw ArgumentError.value(nickname, 'nickname');
    final store = _store!;
    _identity ??= await vault.read(identityKey) ?? await () async {
      final created = await RelayIdentity.generate();
      await vault.write(identityKey, created);
      return created;
    }();
    profile = SocialProfile(nickname: nickname, bound: false);
    await store.saveProfile(profile!);
    status = NearbyStatus.ready;
    _rebuildPresence();
    campusLog('[Nearby] action=enable');
    notifyListeners();
    _syncRadio();
  }

  Future<void> rename(String nickname) async {
    if (!validNickname(nickname)) throw ArgumentError.value(nickname, 'nickname');
    profile = SocialProfile(nickname: nickname, bound: false);
    await _store!.saveProfile(profile!);
    notifyListeners();
  }

  // 删除面对面数据：身份、全部面对面好友与会话（好友那边的记录在他们手机上，删不到）。
  Future<void> clearAll() async {
    await radio.stop();
    await vault.delete(identityKey);
    await _store!.clear();
    _identity = null;
    profile = null;
    _invite = null;
    status = NearbyStatus.setup;
    campusLog('[Nearby] action=clear');
    await _reload();
  }

  Future<void> _reload() async {
    final store = _store;
    if (store == null) return;
    friends = await store.friends();
    _keys = {for (final friend in friends) friend.deviceId: presenceKeyOf(decodeBase64UrlNoPad(friend.signPublicKey, length: 32))};
    _matchPeers();
    notifyListeners();
  }

  // ---------- 蓝牙：页面开着时才开 ----------

  // 面对面页打开时调，关掉时调 release；都关了、或应用退到后台就停。
  void acquire() {
    _users++;
    if (watchLifecycle) {
      _lifecycle ??= AppLifecycleListener(onShow: () {
        _foreground = true;
        _syncRadio();
      }, onHide: () {
        _foreground = false;
        _syncRadio();
      });
    }
    _radioChanges ??= radio.changes.listen((_) {
      _matchPeers();
      notifyListeners();
    });
    _syncRadio();
  }

  void release() {
    if (_users == 0) return;
    _users--;
    if (_users > 0) return;
    _lifecycle?.dispose();
    _lifecycle = null;
    _foreground = true;
    unawaited(_radioChanges?.cancel());
    _radioChanges = null;
    _invite = null;
    _syncRadio();
  }

  void _syncRadio() {
    final wanted = _users > 0 && _foreground && status == NearbyStatus.ready && _identity != null;
    if (wanted) {
      unawaited(radio.start(presence: () => _presence, onPayload: _receive));
    } else if (radio.state != NearbyRadioState.off) {
      unawaited(radio.stop());
      present = const {};
    }
  }

  // 蓝牙被拒、关着时页面给的「去设置」。
  Future<void> openRadioSettings() => radio.openSettings();

  // 重新启动蓝牙（打开了蓝牙或给了权限回来后页面点「重试」）。
  Future<void> retryRadio() async {
    await radio.stop();
    _syncRadio();
  }

  void _rebuildPresence() {
    final identity = _identity;
    _presence = identity == null ? Uint8List(0) : buildPresence(presenceKey: presenceKeyOf(identity.signPublicKey), inviteSeed: _invite?.seed);
  }

  void _matchPeers() {
    final matched = <String, String>{};
    for (final peer in radio.peers) {
      final friendId = presenceFriend(peer.presence, _keys);
      if (friendId != null) matched[friendId] = peer.id;
    }
    present = matched;
  }

  // 收到一整条：与线上同一套规则收下（问候只认 5 分钟内出示过的二维码），收下才回成功。
  Future<bool> _receive(Uint8List payload) async {
    final store = _store, identity = _identity;
    if (store == null || identity == null) return false;
    try {
      await store.pruneInvites(_clock().subtract(inviteLife).toUtc().toIso8601String());
      await acceptEnvelope(store: store, identity: identity, envelope: payload, relayFrom: null, now: _now());
      await _reload();
      return true;
    } catch (error, stack) {
      campusLog('[Nearby] action=accept errorType=${error.runtimeType}\n$stack');
      return false;
    }
  }

  // ---------- 加好友 ----------

  // 出示二维码：本机记下邀请公钥（核对扫码方的问候用），出现标记带上二维码标记让扫码的人在附近找到这台。
  @override
  Future<InviteCode> createInvite() async {
    final store = _store, identity = _identity;
    if (status != NearbyStatus.ready || store == null || identity == null) throw const SocialException(SocialCode.notReady);
    final seed = secureRandomBytes(32);
    final inviteId = base64UrlNoPad(secureRandomBytes(16));
    await store.saveInvite(inviteId, base64UrlNoPad(await ed25519PublicOf(seed)), _now());
    _invite = (id: inviteId, seed: seed);
    _rebuildPresence();
    campusLog('[Nearby] action=create_invite');
    return InviteCode(
      inviteId: inviteId,
      inviteSeed: seed,
      owner: PeerKeys(identity.signPublicKey, identity.boxPublicKey),
      nickname: profile!.nickname,
      expiresAt: _clock().add(inviteLife).millisecondsSinceEpoch,
      prefix: nearbyInvitePrefix,
    );
  }

  // 离开二维码页：不再出示，本机的邀请都作废。
  @override
  Future<void> revokeInvite(String inviteId) async {
    if (_invite?.id == inviteId) {
      _invite = null;
      _rebuildPresence();
    }
    await _store?.pruneInvites(_clock().add(const Duration(seconds: 1)).toUtc().toIso8601String());
  }

  // [人工决策-2026-10-04 16:44:36] 扫码即成为好友（同线上，见 social_service.dart 的 redeem）。
  // 扫码：在附近找到正在出示这张码的手机，把问候（自己的公钥与昵称、邀请凭证，加密给对方）经蓝牙交过去，对方收下就互为好友。
  @override
  Future<SocialFriend> redeem(InviteCode code) async {
    final store = _store, identity = _identity;
    if (status != NearbyStatus.ready || store == null || identity == null) throw const SocialException(SocialCode.notReady);
    if (code.owner.deviceId == identity.deviceId) throw const SocialException(SocialCode.inviteSelf);
    if (code.expiresAt + const Duration(minutes: 1).inMilliseconds < serverNow) throw const SocialException(SocialCode.inviteExpired);
    if (await store.friend(code.owner.deviceId) == null && await store.friendCount() >= friendLimit) throw const SocialException(SocialCode.localFriendLimit);
    if (radio.state != NearbyRadioState.ready) throw const SocialException(SocialCode.nearbyOff);
    final peerId = await _find(code.inviteSeed);
    if (peerId == null) throw const SocialException(SocialCode.nearbyAbsent);
    final helloId = _uuid.v4();
    final proof = await signWithSeed(code.inviteSeed, inviteProofCanonical(code.inviteId, identity.deviceId));
    final hello = await sealEnvelope(
      sender: identity,
      recipient: code.owner,
      message: helloMessage(id: helloId, identity: identity, to: code.owner.deviceId, sentAt: serverNow, nickname: profile!.nickname, inviteId: code.inviteId, proof: proof),
    );
    await _deliverBytes(peerId, hello);
    await store.upsertFriend(deviceId: code.owner.deviceId, nickname: code.nickname, signPublicKey: base64UrlNoPad(code.owner.signPublicKey), boxPublicKey: base64UrlNoPad(code.owner.boxPublicKey), now: _now(), systemId: _uuid.v4());
    campusLog('[Nearby] action=redeem');
    await _reload();
    return (await store.friend(code.owner.deviceId))!;
  }

  // 在附近找正在出示这张码的手机：先重读一遍附近的出现标记，最多等 findTimeout。
  Future<String?> _find(Uint8List inviteSeed) async {
    String? showing() => radio.peers.where((peer) => presenceShows(peer.presence, inviteSeed)).firstOrNull?.id;
    radio.refresh();
    final found = showing();
    if (found != null) return found;
    final completer = Completer<String?>();
    final subscription = radio.changes.listen((_) {
      final id = showing();
      if (id != null && !completer.isCompleted) completer.complete(id);
    });
    try {
      return await completer.future.timeout(findTimeout, onTimeout: () => null);
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _deliverBytes(String peerId, Uint8List bytes) async {
    try {
      await radio.send(peerId, bytes);
    } on NearbyRadioException catch (error) {
      throw SocialException(error.rejected ? SocialCode.nearbyRejected : SocialCode.nearbyFailed);
    }
  }

  // ---------- 卡片 ----------

  // 发送：先在本机记为发送中，对方在附近就经蓝牙交过去；不在附近或没送到记错误码，由用户点重发（同一消息号，对方按消息号去重）。
  @override
  Future<SocialMessage> send(String friendId, ShareCard card) async {
    final store = _store;
    if (status != NearbyStatus.ready || store == null) throw const SocialException(SocialCode.notReady);
    final id = _uuid.v4();
    await store.addCard(id: id, friendId: friendId, outgoing: true, state: MessageState.sending, card: card, now: _now());
    await _reload();
    return _deliver(id);
  }

  @override
  Future<SocialMessage> retry(String messageId) async {
    await _store!.setState(messageId, MessageState.sending);
    notifyListeners();
    return _deliver(messageId);
  }

  Future<SocialMessage> _deliver(String messageId) async {
    final store = _store!, identity = _identity!;
    final message = (await store.message(messageId))!;
    final friend = await store.friend(message.friendId);
    String? error;
    final peerId = present[message.friendId];
    if (friend == null) {
      error = SocialCode.friendRemoved;
    } else if (radio.state != NearbyRadioState.ready) {
      error = SocialCode.nearbyOff;
    } else if (peerId == null) {
      error = SocialCode.nearbyAbsent;
    } else {
      try {
        final envelope = await sealEnvelope(
          sender: identity,
          recipient: PeerKeys(decodeBase64UrlNoPad(friend.signPublicKey, length: 32), decodeBase64UrlNoPad(friend.boxPublicKey, length: 32)),
          message: cardMessage(id: messageId, from: identity.deviceId, to: friend.deviceId, sentAt: serverNow, card: message.card!),
        );
        await _deliverBytes(peerId, envelope);
      } on SocialException catch (failure) {
        error = failure.code;
      } catch (unexpected, stack) {
        campusLog('[Nearby] action=send errorType=${unexpected.runtimeType}\n$stack');
        error = SocialCode.nearbyFailed;
      }
    }
    await store.setState(messageId, error == null ? MessageState.sent : MessageState.failed, error: error);
    // 发成功不带 errorType=（同 social_service.dart 的 _deliver）。
    campusLog('[Nearby] action=send ${error == null ? 'state=sent' : 'state=failed errorType=$error'}');
    await _reload();
    return (await store.message(messageId))!;
  }

  @override
  Future<List<SocialMessage>> conversation(String friendId) => _store!.conversation(friendId);

  @override
  Future<void> markRead(String friendId) async {
    await _store?.markRead(friendId);
    await _reload();
  }

  @override
  Future<void> setRemark(String friendId, String? remark) async {
    await _store!.setRemark(friendId, remark == null || remark.trim().isEmpty ? null : remark.trim());
    await _reload();
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    await _store!.deleteMessage(messageId);
    await _reload();
  }

  // 删除面对面好友：只删本机（蓝牙上通知不到对方），之后对方发来的不再收下。
  @override
  Future<void> removeFriend(String friendId) async {
    await _store!.deleteFriend(friendId);
    campusLog('[Nearby] action=remove_friend');
    await _reload();
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    unawaited(_radioChanges?.cancel());
    super.dispose();
  }
}
