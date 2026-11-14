import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/social/social_spaces.dart';
import 'package:superxd/social/social_store.dart';

// signedOut：没登录应用账号；elsewhere：这个应用账号的私信在另一台手机上（可以接管）。
enum SocialStatus { loading, unavailable, signedOut, disabled, elsewhere, ready, failed }

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
  static const friendMoved = 'FRIEND_MOVED'; // 对方换了设备：好友已改挂到新设备，点重发
  static const identityLost = 'IDENTITY_LOST'; // 安全存储里的身份丢失，需重新开启
  static const signedOut = 'APP_ACCOUNT_SIGNED_OUT'; // 没登录应用账号，或这台手机上那把应用账号密钥已不在任何账号下
}

// 当前应用账号在这台手机上的私信：账号、本机库与身份（还没开启时为空）。切换账号就换一个对象，进行中的操作据此认出自己已经过时。
class _Session {
  _Session(this.account, this.space, this.identity);
  final AppAccountRef account;
  final SocialSpace space;
  SocialIdentity? identity;
  SocialStore get store => space.store;
}

// [人工决策-2026-10-04 16:44:36] 好友与私信的身份跟设备走（独立昵称、不暴露学号），切换教务账号保留，百宝箱未登录也能分享。（「跟设备走」11-14 起由下一条取代，独立昵称、不暴露学号不变。）
// [人工决策-2026-11-14 16:47:34] 私信跟着应用账号（第 4 阶段，用户选「私信要登录应用账号、每个账号一份」，并要求「留好后路，以后不一定锁死绑定教务」）：
// 私信只认当前应用账号（AppAccountRef，组合根按 AppAccounts.current 调 switchAccount），不认是用什么登录的；每个应用账号在这台手机上一份身份与本机库
// （social_spaces.dart），服务端记「账号 → 当前私信设备」。没登录应用账号时私信停用（signedOut）；退出应用账号不动服务器、本机记录留着，再登录接着用。
// 多设备用户选「新手机接管并提示对方」：账号的私信在另一台手机上时（elsewhere）先确认再接管（takeOver）——好友关系改挂到这台，好友那边会话里提示
// 「对方换了设备」并自动发来昵称；新手机的好友名单与公钥由服务器给（这一步信任服务器，靠那条提示让人看得到），那台手机上的聊天记录、备注与没收的消息不过来；
// 被接管的手机变成 elsewhere，可以再接管回去。这台手机旧版留下的设备级私信并进第一次用私信的应用账号（两台手机原来各有好友的，接管后合在一起）。
// 注销应用账号时服务器删掉它的私信设备，本机这份也清掉（[人工决策-2026-11-14 17:56:46] 用户选「一并删除」，组合根接 forgetAccount）。
// 私信编排：本机库、私信身份与中转服务之间的唯一入口，页面只经它读写。
// 联网时机：切到一个应用账号、开启、出示/扫码、发送、刷新（回到前台、进入私信、下拉），以及前台长轮询收消息。除校时重发一次、中转不认这台设备时重新挂账号后重放一次（见 _authorized）外不自动重试。
class SocialService extends ChangeNotifier {
  SocialService({required this.spaces, required this.accountKeys, RelayTransport? transport, this.accountGone, DateTime Function()? clock, Random? random, this.polling = false})
    : _relay = transport == null ? null : RelayClient(transport),
      _clock = clock ?? DateTime.now,
      _random = random ?? Random();
  // 就绪后是否在前台持续长轮询收消息（应用里开启；测试关闭，避免残留请求与定时器）。
  final bool polling;
  // 长轮询每次挂起时长，服务端上限 25 秒。
  static const longPollWait = Duration(seconds: 25);
  final SocialSpaces spaces;
  // 应用账号的设备密钥（挂账号的请求用它签名）。
  final AppAccountVault accountKeys;
  // 中转说应用账号已不在（别处注销、被清理）：组合根让应用账号马上核一次。
  final void Function()? accountGone;
  final RelayClient? _relay;
  final DateTime Function() _clock;
  // 长轮询退避的随机抖动（见 liveRetryDelay）；测试注入固定的随机源。
  final Random _random;
  final _refreshLock = Lock();
  final _switchLock = Lock();
  final _uuid = const Uuid();
  _Session? _session;
  AppAccountRef? _account;
  bool _started = false;
  // 正在进行的重新挂账号（见 _authorized），几个请求同时遇到 UNAUTHORIZED 时共用这一次。
  Future<bool>? _rebinding;
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
  String? get deviceId => _session?.identity?.deviceId;
  // 按服务器校正过的当前时刻（毫秒），用于二维码倒计时。
  int get serverNow => _clock().millisecondsSinceEpoch + (_relay?.clockOffset ?? 0);

  String _now() => _clock().toUtc().toIso8601String();

  // 切到当前应用账号（组合根在同意协议与政策后、AppAccounts.current 变化时调）：同一个账号重复调不动；force 为真时照样重开（暂时不可用后点重试）。
  Future<void> switchAccount(AppAccountRef? account, {bool force = false}) => _switchLock.synchronized(() async {
    if (_started && account == _account && !force) return;
    _started = true;
    _account = account;
    _session = null;
    profile = null;
    friends = const [];
    unread = 0;
    refreshError = null;
    status = SocialStatus.loading;
    notifyListeners();
    try {
      await _open(account);
    } catch (error, stack) {
      campusLog('[Social] action=open errorType=${error.runtimeType}\n$stack');
      status = SocialStatus.failed;
    } finally {
      notifyListeners();
    }
  });

  // 暂时不可用（挂账号时连不上等）后重试。
  Future<void> reopen() => switchAccount(_account, force: true);

  Future<void> _open(AppAccountRef? account) async {
    if (_relay == null) {
      status = SocialStatus.unavailable;
      return;
    }
    if (account == null) {
      status = SocialStatus.signedOut;
      return;
    }
    final space = await spaces.of(account.accountId);
    final session = _session = _Session(account, space, null);
    final saved = await session.store.profile();
    if (saved == null) {
      status = SocialStatus.disabled;
      return;
    }
    final identity = await spaces.vault.read(space.identityKey);
    if (identity == null) {
      // 本机库还在但身份没了（清除了安全存储）：旧好友的消息已无法解密，回到未开启。
      campusLog('[Social] action=open errorType=${SocialCode.identityLost}');
      await session.store.clear();
      status = SocialStatus.disabled;
      return;
    }
    session.identity = identity;
    profile = saved;
    await session.store.failInterrupted();
    await session.store.pruneInvites(_clock().toUtc().subtract(inviteRetention).toIso8601String());
    if (!saved.bound) {
      try {
        await _bind(session, takeover: false);
      } on SocialException catch (error) {
        if (!_suspend(session, error.code)) rethrow;
        return;
      }
    }
    _becomeReady();
    await _reload();
  }

  // 把私信设备挂到这个应用账号（用应用账号的设备密钥签名，没注册过的私信设备顺带登记），成功后记下 bound；返回是否从别的手机接管过来。
  // 账号的私信在另一台手机上抛 SocialException(SOCIAL_ELSEWHERE)；这台手机上没有那把应用账号密钥、或中转说账号不在了抛 SocialException(signedOut)。
  Future<bool> _bind(_Session session, {required bool takeover}) async {
    final identity = session.identity!;
    final key = await accountKeys.read(session.account.slot);
    if (key == null) throw const SocialException(SocialCode.signedOut);
    final bool moved;
    try {
      moved = await _relay!.bindSocial(key.identity, identity, takeover: takeover);
    } on RelayException catch (error) {
      if (error.code == RelayCode.accountNotFound || error.code == RelayCode.unauthorized) {
        accountGone?.call();
        throw const SocialException(SocialCode.signedOut);
      }
      throw SocialException(error.code);
    }
    final nickname = profile?.nickname;
    if (nickname != null && identical(session, _session)) {
      profile = SocialProfile(nickname: nickname, bound: true);
      await session.store.saveProfile(profile!);
    }
    campusLog('[Social] action=bind deviceId=${identity.deviceId} moved=$moved');
    return moved;
  }

  // 私信在另一台手机上、应用账号没了：这台手机的私信停用（长轮询随之停下）。返回是不是这两种情况。
  bool _suspend(_Session session, String code) {
    final next = switch (code) {
      RelayCode.socialElsewhere => SocialStatus.elsewhere,
      SocialCode.signedOut => SocialStatus.signedOut,
      _ => null,
    };
    if (next == null) return false;
    if (identical(session, _session)) {
      status = next;
      campusLog('[Social] action=suspend state=${next.name}');
      notifyListeners();
    }
    return true;
  }

  Future<void> _reload() async {
    final session = _session;
    if (session == null) return;
    final loaded = await session.store.friends();
    final total = await session.store.unreadTotal();
    if (!identical(session, _session)) return;
    friends = loaded;
    unread = total;
    notifyListeners();
  }

  void _becomeReady() {
    status = SocialStatus.ready;
    if (polling) startPolling();
  }

  _Session _ready() {
    final session = _session;
    if (status != SocialStatus.ready || session?.identity == null) throw const SocialException(SocialCode.notReady);
    return session!;
  }

  // [人工决策-2026-11-11 23:16:31] 中转不认这台设备时自动重新注册一次并重放这一次请求（用户 11-11 要求按最佳实践补上 W1 报的缺口）：
  // 中转从旧备份恢复、或设备 400 天不活跃被清掉后，所有签名请求都回 UNAUTHORIZED，以前收不到、发不出，也关不掉私信。
  // 设备号由签名公钥推出、注册自签名且幂等，正常客户端只有中转没有这台设备时才会收到 UNAUTHORIZED，所以照「会话失效自动恢复一次再重放」的做法：
  // 只注册一次、只重放一次，重放后仍失败就照常报错；几个请求同时遇到时共用一次注册。没选「只标记未注册、等用户再点」：
  // 用户看到的会是一次说不清原因的失败。服务端那边的好友关系随设备一起没了，之后发送照常回 NOT_FRIEND 并标记对方已解除，要重新扫码。
  // 11-14 私信跟着应用账号后，「重新注册」换成重新挂到应用账号（同样顺带登记设备）：被别的手机接管了的这里得到 SOCIAL_ELSEWHERE，转成 elsewhere 不再重放。
  Future<T> _authorized<T>(_Session session, Future<T> Function(RelayClient relay, SocialIdentity identity) call) async {
    final relay = _relay!, identity = session.identity!;
    try {
      return await call(relay, identity);
    } on RelayException catch (error) {
      if (error.code != RelayCode.unauthorized) rethrow;
      campusLog('[Social] action=rebind deviceId=${identity.deviceId}');
      try {
        await (_rebinding ??= _bind(session, takeover: false).whenComplete(() => _rebinding = null));
      } on SocialException catch (failure) {
        _suspend(session, failure.code);
        rethrow;
      }
      return call(relay, identity);
    }
  }

  // 开启私信：生成私信身份、保存昵称、挂到当前应用账号。挂不上时身份与昵称已保存，下次打开或再点开启时补挂。
  // 账号的私信在另一台手机上时转成 elsewhere 并抛 SocialException(SOCIAL_ELSEWHERE)，页面问过用户后调 takeOver。
  Future<void> enable(String nickname) async {
    final session = _session;
    if (_relay == null || session == null) throw const SocialException(SocialCode.notReady);
    if (!validNickname(nickname)) throw ArgumentError.value(nickname, 'nickname');
    session.identity ??= await spaces.vault.read(session.space.identityKey) ?? await () async {
      final created = await SocialIdentity.generate();
      await spaces.vault.write(session.space.identityKey, created);
      return created;
    }();
    profile = SocialProfile(nickname: nickname, bound: false);
    await session.store.saveProfile(profile!);
    try {
      await _bind(session, takeover: false);
    } on SocialException catch (error) {
      _suspend(session, error.code);
      notifyListeners();
      rethrow;
    }
    if (!identical(session, _session)) return;
    _becomeReady();
    campusLog('[Social] action=enable deviceId=${session.identity!.deviceId}');
    await _reload();
  }

  // 在这台手机上接管这个应用账号的私信（页面先确认）：好友关系改挂到这台，再从服务器拿好友名单与公钥补齐本机没有的好友。
  Future<void> takeOver() async {
    final session = _session;
    if (session?.identity == null || profile == null || status != SocialStatus.elsewhere) throw const SocialException(SocialCode.notReady);
    await _bind(session!, takeover: true);
    if (!identical(session, _session)) return;
    _becomeReady();
    campusLog('[Social] action=take_over deviceId=${session.identity!.deviceId}');
    notifyListeners();
    await refresh(reconcile: true, importRemote: true);
  }

  // 只改本机昵称：之后出示的二维码与问候带新昵称，已加的好友那边不变。
  Future<void> rename(String nickname) async {
    if (!validNickname(nickname)) throw ArgumentError.value(nickname, 'nickname');
    profile = SocialProfile(nickname: nickname, bound: profile!.bound);
    await _session!.store.saveProfile(profile!);
    notifyListeners();
  }

  // 关闭私信：先请中转服务删除本设备（好友关系、待收消息与挂账号的登记），再清空本机数据与身份。服务端删除失败则不清本机，提示重试。
  // 中转已经不认这台设备（UNAUTHORIZED，含被别的手机接管后）时没有可删的，照样清本机；在另一台手机上（elsewhere）时也能关掉这台的。
  Future<void> disable() async {
    final session = _session;
    if ((status != SocialStatus.ready && status != SocialStatus.elsewhere) || session?.identity == null) throw const SocialException(SocialCode.notReady);
    try {
      await _relay!.deleteDevice(session!.identity!);
    } on RelayException catch (error) {
      if (error.code != RelayCode.unauthorized) throw SocialException(error.code);
      campusLog('[Social] action=disable state=not_registered');
    }
    await _clearLocal(session!);
    campusLog('[Social] action=disable');
  }

  Future<void> _clearLocal(_Session session) async {
    await session.store.clear();
    await spaces.vault.delete(session.space.identityKey);
    session.identity = null;
    if (!identical(session, _session)) return;
    profile = null;
    friends = const [];
    unread = 0;
    status = SocialStatus.disabled;
    notifyListeners();
  }

  // 注销了应用账号（服务器已删掉它的私信设备，见文件头 17:56:46 那条）：清掉这台手机上那个账号的私信，是当前账号时停用。
  Future<void> forgetAccount(AppAccountRef account) => _switchLock.synchronized(() async {
    final current = _session;
    final session = current != null && current.account == account ? current : _Session(account, await spaces.of(account.accountId), null);
    await _clearLocal(session);
    if (identical(session, _session)) {
      status = SocialStatus.signedOut;
      notifyListeners();
    }
    campusLog('[Social] action=forget_account');
  });

  // 出示二维码：新建一次性邀请（服务端同时作废本设备之前的邀请），本机记下邀请公钥用于核验扫码方的问候。
  Future<InviteCode> createInvite() async {
    final session = _ready();
    final inviteSeed = secureRandomBytes(32);
    final inviteId = base64UrlNoPad(secureRandomBytes(16));
    final publicKey = await ed25519PublicOf(inviteSeed);
    final int expiresAt;
    try {
      expiresAt = await _authorized(session, (relay, identity) => relay.createInvite(identity, inviteId, publicKey));
    } on RelayException catch (error) {
      throw SocialException(error.code);
    }
    await session.store.saveInvite(inviteId, base64UrlNoPad(publicKey), _now());
    final identity = session.identity!;
    return InviteCode(inviteId: inviteId, inviteSeed: inviteSeed, owner: PeerKeys(identity.signPublicKey, identity.boxPublicKey), nickname: profile!.nickname, expiresAt: expiresAt);
  }

  // 离开二维码页即作废，不让截图在有效期内继续被扫。失败只记日志：5 分钟后自然过期。
  Future<void> revokeInvite(String inviteId) async {
    try {
      final session = _ready();
      await _relay!.revokeInvite(session.identity!, inviteId);
    } catch (error, stack) {
      campusLog('[Social] action=revoke_invite errorType=${error.runtimeType}\n$stack');
    }
  }

  // [人工决策-2026-10-04 16:44:36] 扫码即成为好友（出示二维码视为同意），不做申请确认；二维码 5 分钟有效、期内可被多人扫。
  // 扫码：用邀请私钥签凭证，连同给对方的问候（自己的公钥与昵称，端到端加密）一起提交；成功后本机加对方为好友。
  Future<SocialFriend> redeem(InviteCode code) async {
    final session = _ready();
    final relay = _relay!, identity = session.identity!, store = session.store;
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
      await _authorized(session, (relay, identity) => relay.redeem(identity, inviteId: code.inviteId, proof: proof, helloId: helloId, hello: hello));
    } on RelayException catch (error) {
      throw SocialException(error.code);
    }
    await store.upsertFriend(deviceId: code.owner.deviceId, nickname: code.nickname, signPublicKey: base64UrlNoPad(code.owner.signPublicKey), boxPublicKey: base64UrlNoPad(code.owner.boxPublicKey), now: _now(), systemId: _uuid.v4());
    campusLog('[Social] action=redeem friendId=${code.owner.deviceId}');
    await _reload();
    return (await store.friend(code.owner.deviceId))!;
  }

  // 拉取信箱：解密、验签、入库后再确认删除；单次最多 20 页（1000 条），剩下的下次刷新继续。并发调用合并为一次。
  // reconcile 为真时顺带核对好友列表（标记已被对方解除的、改挂换了设备的）；importRemote 为真时（刚接管）另把服务器上有、本机没有的好友补进来。
  Future<void> refresh({bool reconcile = false, bool importRemote = false}) {
    final session = _session;
    if (status != SocialStatus.ready || session == null) return Future.value();
    return _refreshLock.synchronized(() async {
      if (!identical(session, _session) || status != SocialStatus.ready) return;
      refreshing = true;
      notifyListeners();
      try {
        String? after;
        var received = 0;
        for (var page = 0; page < 20; page++) {
          final batch = await _authorized(session, (relay, identity) => relay.fetch(identity, after: after));
          received += await _consume(session, batch.messages);
          if (batch.messages.isNotEmpty) after = batch.messages.last.id;
          if (!batch.more) break;
        }
        if (reconcile || importRemote) await _reconcile(session, importRemote: importRemote);
        refreshError = null;
        campusLog('[Social] action=refresh received=$received');
      } on SocialException catch (error) {
        refreshError = error.code;
        campusLog('[Social] action=refresh errorType=${error.code}');
      } on RelayException catch (error) {
        refreshError = error.code;
        campusLog('[Social] action=refresh errorType=${error.code}');
      } catch (error, stack) {
        refreshError = RelayCode.badResponse;
        campusLog('[Social] action=refresh errorType=${error.runtimeType}\n$stack');
      } finally {
        refreshing = false;
        await _reload();
        notifyListeners();
      }
    });
  }

  // 处理一批信箱消息并确认删除，返回新增条数；调用方须持有 _refreshLock。
  // 有不认识的发件人时先核对一次好友列表：可能是换了设备的好友（扫码的问候也来自生人，多核对一次无妨）；核对连不上只记日志，照常收这批。
  Future<int> _consume(_Session session, List<InboxItem> items) async {
    if (items.isEmpty) return 0;
    for (final item in items) {
      if (await session.store.friend(item.from) != null) continue;
      try {
        await _reconcile(session);
      } on RelayException catch (error) {
        campusLog('[Social] action=reconcile errorType=${error.code}');
      }
      break;
    }
    var received = 0;
    for (final item in items) {
      if (await _accept(session, item)) received++;
    }
    await _authorized(session, (relay, identity) => relay.ack(identity, [for (final item in items) item.id]));
    return received;
  }

  // 核对好友列表：换了设备的好友（服务器给的新设备号、新公钥与本机认得的旧号）改挂过来、确认提示，再给它发自己的昵称；
  // 服务端没有、本机还有效的标为对方已解除；importRemote 为真时把服务器上有、本机没有的好友按服务器给的公钥补进来（名字先用占位）。
  Future<void> _reconcile(_Session session, {bool importRemote = false}) async {
    final store = session.store;
    final remote = await _authorized(session, (relay, identity) => relay.friends(identity, keys: importRemote));
    final now = _now();
    final moves = <String>[], greet = <String>[];
    for (final friend in remote.values) {
      final from = friend.movedFrom, keys = friend.keys;
      if (from == null) continue;
      moves.add(friend.deviceId);
      if (keys == null || await store.friend(from) == null) continue;
      await store.relinkFriend(from: from, to: friend.deviceId, signPublicKey: base64UrlNoPad(keys.signPublicKey), boxPublicKey: base64UrlNoPad(keys.boxPublicKey), now: now, systemId: _uuid.v4());
      greet.add(friend.deviceId);
      campusLog('[Social] action=friend_moved friendId=${friend.deviceId}');
    }
    if (importRemote) {
      var count = await store.friendCount();
      for (final friend in remote.values) {
        final keys = friend.keys;
        if (keys == null || count >= friendLimit || await store.friend(friend.deviceId) != null) continue;
        await store.importFriend(deviceId: friend.deviceId, signPublicKey: base64UrlNoPad(keys.signPublicKey), boxPublicKey: base64UrlNoPad(keys.boxPublicKey), now: now);
        count++;
      }
    }
    for (final friend in await store.friends()) {
      if (!friend.removed && !remote.containsKey(friend.deviceId)) await store.markRemoved(friend.deviceId);
    }
    if (moves.isNotEmpty) await _authorized(session, (relay, identity) => relay.ackMoves(identity, moves));
    for (final friendId in greet) {
      await _sendProfile(session, friendId);
    }
  }

  // 给换了设备的好友发自己的昵称（新手机从服务器拿到的好友没有名字）；失败只记日志，不重试。
  Future<void> _sendProfile(_Session session, String friendId) async {
    try {
      final identity = session.identity!, friend = (await session.store.friend(friendId))!;
      final id = _uuid.v4();
      final envelope = await sealEnvelope(
        sender: identity,
        recipient: PeerKeys(decodeBase64UrlNoPad(friend.signPublicKey, length: 32), decodeBase64UrlNoPad(friend.boxPublicKey, length: 32)),
        message: {'v': 1, 'id': id, 'from': identity.deviceId, 'to': friendId, 'sentAt': _clock().millisecondsSinceEpoch, 'kind': 'profile', 'profile': {'nickname': profile!.nickname}},
      );
      await _authorized(session, (relay, identity) => relay.send(identity, to: friendId, clientId: id, envelope: envelope));
      campusLog('[Social] action=send_profile friendId=$friendId state=sent');
    } catch (error, stack) {
      campusLog('[Social] action=send_profile friendId=$friendId errorType=${error.runtimeType}\n$stack');
    }
  }

  // 处理一条信箱消息，返回是否新增了内容。任何不合格的消息都丢弃并记日志（照样确认删除，避免反复拉取同一条坏消息）。
  Future<bool> _accept(_Session session, InboxItem item) async {
    final identity = session.identity!, store = session.store;
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
          return await _acceptHello(store, item.from, message['hello'], opened, id, now);
        case 'card':
          await _verifiedFriend(store, item.from, opened);
          return await store.addCard(id: id, friendId: item.from, outgoing: false, state: MessageState.received, card: decodeShareCard(message['card']), now: now);
        case 'profile':
          await _verifiedFriend(store, item.from, opened);
          final nickname = switch (message['profile']) {
            {'nickname': final String nickname} when validNickname(nickname) => nickname,
            _ => throw const SocialCryptoException('资料格式不正确'),
          };
          await store.setNickname(item.from, nickname);
          return false;
        default:
          throw const SocialCryptoException('未知消息类型');
      }
    } catch (error, stack) {
      campusLog('[Social] action=accept errorType=${error.runtimeType} from=${item.from}\n$stack');
      return false;
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

  // 发送卡片：先在本机记为“发送中”（界面原地显示），再加密投递；失败记错误码，由用户点重发（同一消息号，服务端幂等）。
  Future<SocialMessage> send(String friendId, ShareCard card) async {
    final session = _ready();
    final id = _uuid.v4();
    await session.store.addCard(id: id, friendId: friendId, outgoing: true, state: MessageState.sending, card: card, now: _now());
    await _reload();
    return _deliver(session, id);
  }

  Future<SocialMessage> retry(String messageId) async {
    final session = _ready();
    await session.store.setState(messageId, MessageState.sending);
    notifyListeners();
    return _deliver(session, messageId);
  }

  Future<SocialMessage> _deliver(_Session session, String messageId) async {
    final store = session.store;
    final message = (await store.message(messageId))!;
    final friend = await store.friend(message.friendId);
    String? error;
    if (friend == null || friend.removed) {
      error = SocialCode.friendRemoved;
    } else {
      try {
        final identity = session.identity!;
        final envelope = await sealEnvelope(
          sender: identity,
          recipient: PeerKeys(decodeBase64UrlNoPad(friend.signPublicKey, length: 32), decodeBase64UrlNoPad(friend.boxPublicKey, length: 32)),
          message: {'v': 1, 'id': messageId, 'from': identity.deviceId, 'to': friend.deviceId, 'sentAt': _clock().millisecondsSinceEpoch, 'kind': 'card', 'card': encodeShareCard(message.card!)},
        );
        await _authorized(session, (relay, identity) => relay.send(identity, to: friend.deviceId, clientId: messageId, envelope: envelope));
      } on RelayException catch (relayError) {
        error = relayError.code;
        if (relayError.code == RelayCode.notFriend) error = await _notFriend(session, friend.deviceId);
      } on SocialException catch (failure) {
        error = failure.code;
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

  // 发送被拒「不是好友」：可能是对方换了设备、这边还没核对。先核对好友列表，改挂到新设备的报 FRIEND_MOVED（会话已跟过去，点重发即可），
  // 还在旧号上的才算对方已解除；核对失败照旧按已解除处理。
  Future<String> _notFriend(_Session session, String friendId) async {
    try {
      await _reconcile(session);
      if (await session.store.friend(friendId) == null) return SocialCode.friendMoved;
    } on SocialException catch (failure) {
      return failure.code;
    } catch (error, stack) {
      campusLog('[Social] action=reconcile errorType=${error.runtimeType}\n$stack');
    }
    await session.store.markRemoved(friendId);
    return RelayCode.notFriend;
  }

  Future<List<SocialMessage>> conversation(String friendId) => _session!.store.conversation(friendId);

  Future<void> markRead(String friendId) async {
    await _session?.store.markRead(friendId);
    await _reload();
  }

  Future<void> setRemark(String friendId, String? remark) async {
    await _session!.store.setRemark(friendId, remark == null || remark.trim().isEmpty ? null : remark.trim());
    await _reload();
  }

  Future<void> deleteMessage(String messageId) async {
    await _session!.store.deleteMessage(messageId);
    await _reload();
  }

  // 删除好友：服务端双向解除（对方之后发来的被拒收），本机删除会话。对方已解除时服务端无关系可删，直接删本机。
  Future<void> removeFriend(String friendId) async {
    final session = _ready();
    try {
      await _authorized(session, (relay, identity) => relay.removeFriend(identity, friendId));
    } on RelayException catch (error) {
      throw SocialException(error.code);
    }
    await session.store.deleteFriend(friendId);
    campusLog('[Social] action=remove_friend friendId=$friendId');
    await _reload();
  }

  // [人工决策-2026-10-04 22:10:46] 收消息用前台长轮询（不接厂商推送，后台收不到）：应用在前台且私信就绪时始终挂着一个拉取请求，
  // 有新消息服务端立即返回，接近实时；没有就 25 秒后空返回再挂。回到前台先拉一次并核对好友，进入后台不再发起（在途请求自然结束）。
  // 网络失败按 2、4、8…秒退避、上限 60 秒；空响应快于 5 秒（服务端满载时会立即返回）也等满 5 秒，防止空转。
  // 切换应用账号时旧账号那一轮在途请求回来后不再处理、随即让位给新账号的一轮（最多等一次挂起时长）。
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

  bool _keepLive(_Session session) => polling && _foreground && !_disposed && status == SocialStatus.ready && identical(session, _session);

  void _live() {
    final session = _session;
    if (_living || session == null || !_keepLive(session)) return;
    _living = true;
    _background(_liveLoop(session));
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

  Future<void> _liveLoop(_Session session) async {
    var backoff = const Duration(seconds: 2);
    var failures = 0;
    try {
      while (_keepLive(session)) {
        final started = _clock();
        try {
          final batch = await _authorized(session, (relay, identity) => relay.fetch(identity, wait: longPollWait));
          if (!_keepLive(session)) break;
          backoff = const Duration(seconds: 2);
          failures = 0;
          if (batch.messages.isNotEmpty) {
            final received = await _refreshLock.synchronized(() => _consume(session, batch.messages));
            campusLog('[Social] action=live received=$received');
            await _reload();
            continue;
          }
          final elapsed = _clock().difference(started);
          if (elapsed < const Duration(seconds: 5)) await Future<void>.delayed(const Duration(seconds: 5) - elapsed);
        } on SocialException catch (error) {
          // 私信被别的手机接管或应用账号没了（已转成 elsewhere、signedOut）：停下。
          campusLog('[Social] action=live state=stopped code=${error.code}');
          break;
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
      // 换了账号：让新账号接着收。
      if (!identical(session, _session)) _live();
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
