import 'dart:async';

import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/rollouts.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/domain/unlock.dart';

// 解锁的编排（设备级，人工决策见服务端 src/modules/unlock/unlock_rules.ts）：清单来自灰度配置（Rollouts.config），这个账号能用哪些问服务器（UnlockClient）。
// 本机判定：下架的锁着、公开了的开着（没登录也开），其余看服务器给的；清单里没有要账号才开的项、或没登录应用账号时不联网。
// 同意协议与政策之后组合根调 start 才开始联网；之后拉到新配置、切换应用账号时重问一次，回到前台时距上次超过 refreshGap 再问，
// 积分页打开时直接 refresh；中转说应用账号不在了就让 AppAccounts 马上核一次。
// accountOn 为假（联网偏好是仅本机，人工决策见 domain/network_policy.dart）时只认公开与下架、不联网，偏好变了组合根调 reconsider。
class Unlocks implements UnlockAccess {
  Unlocks({required this.rollouts, required this.appAccounts, required this.client, bool Function()? accountOn, DateTime Function()? now})
    : _accountOn = accountOn ?? (() => true),
      _now = now ?? DateTime.now {
    rollouts.addListener(_configChanged);
    appAccounts.addListener(_accountChanged);
  }
  final Rollouts rollouts;
  final AppAccounts appAccounts;
  final UnlockClient client;
  final bool Function() _accountOn;
  final DateTime Function() _now;
  final _changes = StreamController<void>.broadcast();
  // 服务器给的状态与它属于哪个应用账号（换了账号就不再作数）。
  UnlockState? _state;
  AppAccountRef? _stateOf;
  AppAccountRef? _account;
  var _started = false;
  DateTime? _fetchedAt;

  static const refreshGap = Duration(hours: 1);

  @override
  Stream<void> get changes => _changes.stream;

  List<RolloutUnlock> get _specs => rollouts.config.unlocks;

  RolloutUnlock? _spec(String id) => _specs.where((spec) => spec.id == id).firstOrNull;

  @override
  bool locked(String id) {
    final spec = _spec(id);
    if (spec == null) return false;
    if (spec.retired) return true;
    if (spec.isPublic(_now())) return false;
    final state = _state, account = appAccounts.current;
    return !(_accountOn() && state != null && account != null && account == _stateOf && state.open.contains(id));
  }

  @override
  RolloutUnlock? offer(String id) => switch (_spec(id)) {
    final spec? when !spec.retired && locked(id) => spec,
    _ => null,
  };

  @override
  List<RolloutUnlock> get purchasable => [for (final spec in _specs) if (spec.price != null && offer(spec.id) != null) spec];

  void start() {
    _started = true;
    unawaited(refresh());
  }

  Future<void> foreground() async {
    final fetchedAt = _fetchedAt;
    if (_started && (fetchedAt == null || _now().difference(fetchedAt) >= refreshGap)) await refresh();
  }

  // 联网偏好变了或删了游乐场与积分的数据：旧状态作废、页面重画，开着就重问一次。
  void reconsider() {
    _state = null;
    _changes.add(null);
    if (_started) unawaited(refresh());
  }

  void _configChanged() {
    _changes.add(null);
    if (_started) unawaited(refresh());
  }

  void _accountChanged() {
    final account = appAccounts.current;
    if (account == _account) return;
    _account = account;
    _changes.add(null);
    if (_started) unawaited(refresh());
  }

  @override
  Future<void> refresh() async {
    final account = appAccounts.current;
    final now = _now();
    // 只有要账号才开的项（等级、价格、抽签）没公开、没下架时才问服务器。
    if (account == null || !_accountOn() || !_specs.any((spec) => !spec.retired && !spec.isPublic(now) && (spec.minLevel != null || spec.price != null || spec.percent != null))) return;
    try {
      _apply(account, await client.state(account));
    } on UnlockException catch (error) {
      campusLog('[Unlocks] action=refresh failure=${error.failure.name}');
      if (error.failure == UnlockFailure.notSignedIn) unawaited(appAccounts.check(force: true));
    }
  }

  @override
  Future<void> buy(String id) async {
    final account = appAccounts.current;
    if (account == null) throw const UnlockException(UnlockFailure.notSignedIn, '请先登录应用账号');
    try {
      _apply(account, await client.buy(account, id));
      campusLog('[Unlocks] action=buy');
    } on UnlockException catch (error) {
      campusLog('[Unlocks] action=buy failure=${error.failure.name}');
      if (error.failure == UnlockFailure.notSignedIn) unawaited(appAccounts.check(force: true));
      rethrow;
    }
  }

  void _apply(AppAccountRef account, UnlockState state) {
    if (account != appAccounts.current) return;
    _state = state;
    _stateOf = account;
    _fetchedAt = _now();
    _changes.add(null);
  }
}
