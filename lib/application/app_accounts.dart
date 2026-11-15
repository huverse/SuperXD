import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/gateway/account_access.dart';

// 页面发起一次应用账号操作的结果：做完了（可带一句提示）、学号已有应用账号要授权（扫码或找回）、出示了授权二维码、还在等批准、或失败（原因给用户看）。
sealed class AppAccountResult {
  const AppAccountResult();
}

final class AppAccountDone extends AppAccountResult {
  const AppAccountDone([this.notice]);
  final String? notice;
}

final class AppAccountNeedsAuthorization extends AppAccountResult {
  const AppAccountNeedsAuthorization(this.recovery);
  // 这台手机之前提交的找回申请（没提交过为空）。
  final AppAccountRecovery? recovery;
}

final class AppAccountJoinStarted extends AppAccountResult {
  const AppAccountJoinStarted(this.join);
  final AppAccountJoin join;
}

final class AppAccountWaiting extends AppAccountResult {
  const AppAccountWaiting();
}

final class AppAccountError extends AppAccountResult {
  const AppAccountError(this.message);
  final String message;
}

// 应用账号的编排（设备级，切换教务账号不重建）。
// [人工决策-2026-11-13 22:06:22] 用户三项都选推荐（第 3 项 11-15 起作废，见下）：
// 1. 应用账号跟着教务走：每个教务账号一个应用账号，切换教务就看那个账号的（本机按教务身份分开存）；退出教务时这台设备上的应用账号一并退出
//    （组合根 main.dart 的 watchAppAccounts 接 AccountAccess.loggedOut）。登录状态在这里是独立的对象，「跟着走」只是组合根的一条规则，以后加别的登录方式时换掉它。
// 2. 按需核对：用户在账号页点「登录应用账号」、单独同意后才核对，以后挑战、积分第一次用到时再引导。
// 3. （作废）中转代登录挤掉本机教务会话后紧接着重登：11-15 起改为设备核对，中转不再登录教务（人工决策见 domain/app_account.dart）。
// [人工决策-2026-11-15 15:24:56] 设备核对之后学号已有应用账号、还有设备登着时（用户选「老设备扫码授权新设备」「设备核对 + 风险规则」与「退出了直接登回，丢了走等待期」）：
// 用已登录的手机扫码授权，或申请找回（等 3 天，账号的设备打开应用时提醒、可以拒绝或同意）。
// 提醒怎么出现是实现上的选择：别的设备的找回申请随 check 带回，经打扰时机弹一次（排在最前，见 app_moments.dart），账号页也列着。
class AppAccounts extends ChangeNotifier {
  AppAccounts({required this.accounts, required this.client, this.onDeleted, DateTime Function()? now}) : _now = now ?? DateTime.now {
    accounts.addListener(_accountsChanged);
  }
  final AccountAccess accounts;
  final AppAccountClient client;
  // 注销成功后（服务器已删掉账号下的数据）：组合根接上清掉这台手机上那个账号的私信（人工决策见 social/social_service.dart）。
  final void Function(AppAccountRef account)? onDeleted;
  final DateTime Function() _now;

  // 联网看账号至少隔这么久：顺带让服务器记最后活跃、带回别的设备提交的找回申请（找回等 3 天，隔一小时足够在生效前提醒到）。
  static const checkGap = Duration(hours: 1);

  AccountIdentity? _identity;
  AppAccountRef? _account;
  AppAccountRecovery? _recovery;
  List<AppAccountPendingRecovery> _recoveries = const [];
  final _shownRecoveries = <String>{};
  bool _loaded = false;
  bool _busy = false;
  DateTime? _checkedAt;
  int _epoch = 0;

  // 当前的应用账号（人工决策见 domain/app_account.dart 的 AppAccountRef）：挑战、节日抽奖、诊断包、私信都只认它；没登录为空。
  AppAccountRef? get current => _account;
  // 它的账号号（灰度与分批更新按它分桶）。
  String? get accountId => _account?.accountId;
  // 没登录时这台手机提交的找回申请（check 之后才知道）。
  AppAccountRecovery? get recovery => _recovery;
  // 登录着时别的设备提交、等待中的找回申请。
  List<AppAccountPendingRecovery> get recoveries => _recoveries;
  // 这次启动还没提醒过的一条（打扰时机弹它）。
  AppAccountPendingRecovery? get unseenRecovery => _recoveries.where((item) => !_shownRecoveries.contains(item.id)).firstOrNull;
  bool get loaded => _loaded;
  bool get busy => _busy;

  static bool _same(AccountIdentity? left, AccountIdentity? right) => left?.source == right?.source && left?.loginId == right?.loginId;

  void _accountsChanged() {
    if (!_same(accounts.activeIdentity, _identity)) load().catchError((Object error, StackTrace stack) => campusLog('[AppAccounts] action=load errorType=${error.runtimeType}\n$stack'));
  }

  // 读当前教务账号在本机记着的应用账号（不联网）。
  Future<void> load() async {
    final identity = accounts.activeIdentity;
    final epoch = ++_epoch;
    _identity = identity;
    final account = identity == null ? null : await client.accountOf(identity);
    if (epoch != _epoch) return;
    _account = account;
    _recovery = null;
    _recoveries = const [];
    _loaded = true;
    _checkedAt = null;
    notifyListeners();
  }

  bool _current(AccountIdentity identity) => _same(accounts.activeIdentity, identity) && _same(_identity, identity);

  Future<AppAccountResult> _run(String action, Future<AppAccountResult> Function() body) async {
    if (_busy) return const AppAccountError('上一步还没做完');
    _busy = true;
    notifyListeners();
    var lost = false;
    try {
      final result = await body();
      campusLog('[AppAccounts] action=$action result=${result.runtimeType}');
      return result;
    } on AppAccountException catch (error) {
      campusLog('[AppAccounts] action=$action failure=${error.failure.name}');
      lost = error.failure == AppAccountFailure.notSignedIn && _account != null;
      return AppAccountError(error.message);
    } catch (error, stack) {
      campusLog('[AppAccounts] action=$action errorType=${error.runtimeType}\n$stack');
      return const AppAccountError('应用账号操作没有完成，请重试');
    } finally {
      _busy = false;
      notifyListeners();
      // 中转说这台设备已不在账号里（别处注销、被清理）：马上核一次，本机退回未登录。
      if (lost) unawaited(check(force: true));
    }
  }

  AppAccountResult _signedIn(AppAccountRef account) {
    _account = account;
    _recovery = null;
    _recoveries = const [];
    _checkedAt = _now();
    notifyListeners();
    return const AppAccountDone('已登录应用账号');
  }

  // 用当前教务账号登录应用账号（设备核对：手机已登录教务，把学号交给中转）。学号已有应用账号时先看这台手机的找回申请生效没有。
  Future<AppAccountResult> signIn() => _run('sign_in', () async {
    final identity = accounts.activeIdentity;
    if (identity == null || !_same(identity, _identity)) return const AppAccountError('请先登录教务账号');
    final step = await client.signInWithDevice(identity);
    if (!_current(identity)) return const AppAccountError('教务账号已切换');
    if (step case AppAccountSignedIn(:final account)) return _signedIn(account);
    final recovery = await client.recoveryOf(identity);
    if (!_current(identity)) return const AppAccountError('教务账号已切换');
    if (recovery?.state == AppAccountRecoveryState.granted) {
      final account = await client.accountOf(identity);
      if (account != null) return _signedIn(account);
    }
    _recovery = recovery;
    _checkedAt = _now();
    return AppAccountNeedsAuthorization(recovery);
  });

  // 扫码授权，新设备这一侧：出示二维码（设备核对之后才有）。
  Future<AppAccountResult> startJoin() => _run('start_join', () async {
    final identity = _identity;
    if (identity == null || !_current(identity)) return const AppAccountError('教务账号已切换');
    return AppAccountJoinStarted(await client.startJoin(identity));
  });

  // 出示二维码时页面定时问一次批准了没有；连不上照旧等（不打断出示），过期或不对就报错。不占 busy，不挡账号页别的操作。
  Future<AppAccountResult> pollJoin(AppAccountJoin join) async {
    final identity = _identity;
    if (identity == null || !_current(identity)) return const AppAccountError('教务账号已切换');
    try {
      final account = await client.joinState(identity, join);
      if (account == null) return const AppAccountWaiting();
      if (!_current(identity)) return const AppAccountError('教务账号已切换');
      campusLog('[AppAccounts] action=join result=approved');
      return _signedIn(account);
    } on AppAccountException catch (error) {
      campusLog('[AppAccounts] action=poll_join failure=${error.failure.name}');
      return error.failure == AppAccountFailure.network ? const AppAccountWaiting() : AppAccountError(error.message);
    } catch (error, stack) {
      campusLog('[AppAccounts] action=poll_join errorType=${error.runtimeType}\n$stack');
      return const AppAccountError('应用账号操作没有完成，请重试');
    }
  }

  // 登录着的设备批准扫到的授权二维码（页面已请用户核对过 6 位码）。
  Future<AppAccountResult> approveJoin(String payload) => _run('approve_join', () async {
    final identity = _identity;
    if (identity == null || _account == null) return const AppAccountError('没有登录应用账号');
    await client.approveJoin(identity, payload);
    return const AppAccountDone('已授权新设备');
  });

  // 申请找回（设备核对之后才有）：已经到了生效时刻的顺手问一次，生效就登录。
  Future<AppAccountResult> requestRecovery() => _run('request_recovery', () async {
    final identity = _identity;
    if (identity == null || !_current(identity)) return const AppAccountError('教务账号已切换');
    var recovery = await client.requestRecovery(identity);
    if (!recovery.grantAt.isAfter(_now())) recovery = await client.recoveryOf(identity) ?? recovery;
    if (!_current(identity)) return const AppAccountError('教务账号已切换');
    if (recovery.state == AppAccountRecoveryState.granted) {
      final account = await client.accountOf(identity);
      if (account != null) return _signedIn(account);
    }
    _recovery = recovery;
    _checkedAt = _now();
    return const AppAccountDone('已申请找回');
  });

  // 账号的设备处理一条别的设备提交的找回申请；已经处理过（别的设备处理了、或已生效）也从列表里拿掉。
  Future<AppAccountResult> decideRecovery(String recoveryId, {required bool approve}) => _run('decide_recovery', () async {
    final identity = _identity;
    if (identity == null || _account == null) return const AppAccountError('没有登录应用账号');
    try {
      await client.decideRecovery(identity, recoveryId, approve: approve);
    } on AppAccountException catch (error) {
      if (error.failure != AppAccountFailure.joinExpired) rethrow;
      _recoveries = [for (final item in _recoveries) if (item.id != recoveryId) item];
      return AppAccountError(error.message);
    }
    _recoveries = [for (final item in _recoveries) if (item.id != recoveryId) item];
    return AppAccountDone(approve ? '已同意找回' : '已拒绝找回');
  });

  // 打扰时机弹过这条了（这次启动不再弹，账号页照样列着）。
  void markRecoveryShown(String recoveryId) => _shownRecoveries.add(recoveryId);

  Future<AppAccountResult> signOut() => _run('sign_out', () async {
    final identity = _identity;
    if (identity == null || _account == null) return const AppAccountDone();
    await client.signOut(identity);
    if (_same(identity, _identity)) {
      _account = null;
      _recoveries = const [];
    }
    return const AppAccountDone('已退出应用账号');
  });

  // 注销：服务端删掉账号与全部设备上的登录，本机随之退出。
  Future<AppAccountResult> deleteAccount() => _run('delete', () async {
    final identity = _identity, account = _account;
    if (identity == null || account == null) return const AppAccountDone();
    await client.delete(identity);
    onDeleted?.call(account);
    if (_same(identity, _identity)) {
      _account = null;
      _recoveries = const [];
    }
    return const AppAccountDone('应用账号已注销');
  });

  // 退出教务时跟着退出这个教务账号的应用账号（组合根接线，连同等待中的找回）：退出本身不经页面，失败只记日志。
  Future<void> forget(AccountIdentity identity) async {
    try {
      await client.signOut(identity);
    } catch (error, stack) {
      campusLog('[AppAccounts] action=forget errorType=${error.runtimeType}\n$stack');
    }
    if (_same(identity, _identity) && (_account != null || _recovery != null)) {
      _account = null;
      _recovery = null;
      _recoveries = const [];
      notifyListeners();
    }
  }

  // 启动（同意协议与政策之后）与回到前台时由组合根调，距上次超过 checkGap 才联网：登录着的看一眼账号（别处注销或被清理就退回未登录，
  // 带回别的设备的找回申请）；没登录、这台手机有等待中的找回的问一次进度（生效了就登录；被拒绝或冲突了不再问）。
  // force：挑战或积分那边中转说这个应用账号已不在了，不等间隔马上核一次。
  Future<void> check({bool force = false}) async {
    final identity = _identity, checkedAt = _checkedAt;
    if (identity == null || _busy || (!force && checkedAt != null && _now().difference(checkedAt) < checkGap)) return;
    if (_account == null && _recovery != null && _recovery!.state != AppAccountRecoveryState.pending) return;
    _checkedAt = _now();
    try {
      if (_account == null) {
        final recovery = await client.recoveryOf(identity);
        if (recovery == null || !_same(identity, _identity) || _account != null) return;
        final account = recovery.state == AppAccountRecoveryState.granted ? await client.accountOf(identity) : null;
        if (!_same(identity, _identity) || _account != null) return;
        campusLog('[AppAccounts] action=check_recovery state=${recovery.state.name}');
        if (account != null) {
          _signedIn(account);
          return;
        }
        _recovery = recovery;
        notifyListeners();
        return;
      }
      final summary = await client.summary(identity);
      if (!_same(identity, _identity) || _account == null) return;
      _recoveries = summary.recoveries;
      notifyListeners();
    } on AppAccountException catch (error) {
      campusLog('[AppAccounts] action=check failure=${error.failure.name}');
      if (error.failure == AppAccountFailure.notSignedIn && _same(identity, _identity) && _account != null) {
        _account = null;
        _recoveries = const [];
        notifyListeners();
      }
    } catch (error, stack) {
      campusLog('[AppAccounts] action=check errorType=${error.runtimeType}\n$stack');
    }
  }

  @override
  void dispose() {
    accounts.removeListener(_accountsChanged);
    super.dispose();
  }
}
