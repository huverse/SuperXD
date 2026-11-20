import 'dart:async';

import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/pass.dart';

// 积分时长券的编排 Passes（设备级，人工决策见 domain/pass.dart）：清单与当前应用账号买到哪天都先记在本机，离线照本机记的判定；
// refresh 由用到的页面（电影院打开时）调：联网偏好是联网时拉清单（免签名），登录着应用账号再问自己的券。仅本机时不联网、只认本机记的。
// 当前应用账号由组合根注入（account 与它的账号号 accountId，没登录为空；accountGone 是中转说账号已不在时让应用账号马上核一次）。
class Passes implements PassAccess {
  Passes({required this.memory, required this.client, required this._account, required this._accountId, this._accountGone, bool Function()? online, DateTime Function()? now})
    : _online = online ?? (() => true),
      _now = now ?? DateTime.now;
  final PassMemory memory;
  final PassClient client;
  final AppAccountRef? Function() _account;
  final String? Function() _accountId;
  final Future<void> Function()? _accountGone;
  final bool Function() _online;
  final DateTime Function() _now;
  final _changes = StreamController<void>.broadcast();
  Future<void>? _refreshing;
  // 上次去拉的时刻与当时的应用账号（换了账号不等间隔）。
  DateTime? _refreshedAt;
  String? _refreshedFor;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  PassOffer? offer(String id) => memory.offers.where((offer) => offer.id == id).firstOrNull;

  @override
  DateTime? until(String id) {
    final accountId = _accountId();
    final until = accountId == null ? null : memory.heldOf(accountId)[id];
    return until != null && until.isAfter(_now().toUtc()) ? until : null;
  }

  @override
  bool locked(String id) => offer(id) != null && until(id) == null;

  @override
  bool get canBuy => _online() && _account() != null;

  @override
  Future<void> refresh({bool force = false}) => _refreshing ??= _refresh(force).whenComplete(() => _refreshing = null);

  Future<void> _refresh(bool force) async {
    if (!_online()) return;
    final now = _now(), accountId = _accountId(), last = _refreshedAt;
    if (!force && last != null && accountId == _refreshedFor && now.difference(last) < passRefreshGap) return;
    _refreshedAt = now;
    _refreshedFor = accountId;
    try {
      await memory.saveOffers(await client.offers());
      final account = _account(), accountId = _accountId();
      if (account != null && accountId != null && memory.offers.isNotEmpty) await memory.saveHeld(accountId, await client.held(account));
      _changes.add(null);
    } on PassException catch (error) {
      campusLog('[Pass] action=refresh errorType=PassException failure=${error.failure.name}');
      if (error.failure == PassFailure.notSignedIn) unawaited(_accountGone?.call().catchError((Object error, StackTrace stack) => campusLog('[Pass] action=account_check errorType=${error.runtimeType}\n$stack')));
    }
  }

  @override
  Future<void> buy(String id) async {
    final account = _account(), accountId = _accountId();
    if (account == null || accountId == null) throw const PassException(PassFailure.notSignedIn, '请先登录应用账号');
    if (!_online()) throw const PassException(PassFailure.network, '仅本机时不能用积分换，切回联网再试');
    await memory.saveHeld(accountId, await client.buy(account, id));
    campusLog('[Pass] action=buy pass=$id');
    _changes.add(null);
  }
}
