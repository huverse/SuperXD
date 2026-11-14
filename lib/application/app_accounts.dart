import 'package:flutter/foundation.dart';

import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/gateway_code.dart';
import 'package:superxd/gateway/account_access.dart';

// 页面发起一次应用账号操作的结果：做完了（可带一句提示）、要输一次教务密码、要答验证码、或失败（原因给用户看）。
sealed class AppAccountResult {
  const AppAccountResult();
}

final class AppAccountDone extends AppAccountResult {
  const AppAccountDone([this.notice]);
  final String? notice;
}

final class AppAccountPasswordNeeded extends AppAccountResult {
  const AppAccountPasswordNeeded();
}

final class AppAccountNeedsCaptcha extends AppAccountResult {
  const AppAccountNeedsCaptcha(this.captcha);
  final CaptchaView captcha;
}

final class AppAccountError extends AppAccountResult {
  const AppAccountError(this.message);
  final String message;
}

class _PendingSignIn {
  _PendingSignIn(this.identity, this.proof, this.password);
  final AccountIdentity identity;
  final KingoSignInProof proof;
  // 没记住账号时用户这次输的教务密码：中转代登录挤掉本机会话后拿它重登，用完即丢。
  final String? password;
}

// 应用账号的编排（设备级，切换教务账号不重建）。
// [人工决策-2026-11-13 22:06:22] 用户三项都选推荐：
// 1. 应用账号跟着教务走：每个教务账号一个应用账号，切换教务就看那个账号的（本机按教务身份分开存）；退出教务时这台设备上的应用账号一并退出
//    （组合根 main.dart 的 watchAppAccounts 接 AccountAccess.loggedOut）。登录状态在这里是独立的对象，「跟着走」只是组合根的一条规则，以后加别的登录方式时换掉它。
// 2. 按需核对：用户在账号页点「登录应用账号」、单独同意后才核对（密码经中转那一步），以后挑战、积分第一次用到时再引导；记住了账号的不用再输密码。
// 3. 中转代登录会挤掉本机的教务会话（教务单会话），核对通过后紧接着用同一个密码重登（AccountAccess.refreshSession，不换代次、页面不动）。
class AppAccounts extends ChangeNotifier {
  AppAccounts({required this.accounts, required this.client, DateTime Function()? now}) : _now = now ?? DateTime.now {
    accounts.addListener(_accountsChanged);
  }
  final AccountAccess accounts;
  final AppAccountClient client;
  final DateTime Function() _now;

  // 联网看账号（顺带让服务器记最后活跃、发现别处注销）至少隔这么久：账号 400 天没查看才会被清，一天一次足够。
  static const checkGap = Duration(hours: 24);

  AccountIdentity? _identity;
  AppAccountRef? _account;
  bool _loaded = false;
  bool _busy = false;
  _PendingSignIn? _pending;
  DateTime? _checkedAt;
  int _epoch = 0;

  // 当前的应用账号（人工决策见 domain/app_account.dart 的 AppAccountRef）：挑战、节日抽奖、诊断包、私信都只认它；没登录为空。
  AppAccountRef? get current => _account;
  // 它的账号号（灰度与分批更新按它分桶）。
  String? get accountId => _account?.accountId;
  bool get loaded => _loaded;
  bool get busy => _busy;

  static bool _same(AccountIdentity? left, AccountIdentity? right) => left?.source == right?.source && left?.loginId == right?.loginId;

  void _accountsChanged() {
    if (!_same(accounts.activeIdentity, _identity)) load().catchError((Object error, StackTrace stack) => campusLog('[AppAccounts] action=load errorType=${error.runtimeType}\n$stack'));
  }

  // 读当前教务账号在本机记着的应用账号（不联网）；换了教务账号就丢掉上一个没答完的验证码。
  Future<void> load() async {
    final identity = accounts.activeIdentity;
    final epoch = ++_epoch;
    _cancelPending();
    _identity = identity;
    final account = identity == null ? null : await client.accountOf(identity);
    if (epoch != _epoch) return;
    _account = account;
    _loaded = true;
    _checkedAt = null;
    notifyListeners();
  }

  bool _current(AccountIdentity identity) => _same(accounts.activeIdentity, identity) && _same(_identity, identity);

  Future<AppAccountResult> _run(String action, Future<AppAccountResult> Function() body) async {
    if (_busy) return const AppAccountError('上一步还没做完');
    _busy = true;
    notifyListeners();
    try {
      final result = await body();
      campusLog('[AppAccounts] action=$action result=${result.runtimeType}');
      return result;
    } catch (error, stack) {
      campusLog('[AppAccounts] action=$action errorType=${error.runtimeType}\n$stack');
      return const AppAccountError('应用账号操作没有完成，请重试');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // 用当前教务账号登录应用账号：没给密码时用记住的；没记住就要页面请用户输一次。
  Future<AppAccountResult> signIn({String? password}) => _run('sign_in', () async {
    final identity = accounts.activeIdentity;
    if (identity == null || !_same(identity, _identity)) return const AppAccountError('请先登录教务账号');
    _cancelPending();
    final proof = await accounts.appAccountProof(password: password);
    if (!proof.ok || proof.data == null) return proof.error?.code == GatewayCode.passwordNeeded ? const AppAccountPasswordNeeded() : AppAccountError(proof.error?.message ?? '没能读到记住的账号');
    final pending = _pending = _PendingSignIn(identity, proof.data!, password);
    return _step(pending, null);
  });

  // 答验证码；换一张就是重新发起这一次（服务器的挑战号只能用一次）。
  Future<AppAccountResult> answerCaptcha(String code) => _run('captcha', () async {
    final pending = _pending;
    if (pending == null || !_current(pending.identity)) return const AppAccountError('请重新登录应用账号');
    return _step(pending, code);
  });

  Future<AppAccountResult> refreshCaptcha() => _run('captcha_refresh', () async {
    final pending = _pending;
    if (pending == null || !_current(pending.identity)) return const AppAccountError('请重新登录应用账号');
    client.abandon(pending.identity);
    return _step(pending, null);
  });

  void cancelSignIn() => _cancelPending();

  void _cancelPending() {
    final pending = _pending;
    _pending = null;
    if (pending != null) client.abandon(pending.identity);
  }

  Future<AppAccountResult> _step(_PendingSignIn pending, String? captcha) async {
    final AppAccountStep step;
    try {
      step = await client.signInWithKingo(pending.identity, pending.proof, captcha: captcha);
    } on AppAccountException catch (error) {
      if (identical(_pending, pending)) _pending = null;
      return AppAccountError(error.message);
    }
    if (!identical(_pending, pending) || !_current(pending.identity)) return const AppAccountError('教务账号已切换');
    switch (step) {
      case AppAccountCaptcha(:final captcha):
        return AppAccountNeedsCaptcha(captcha);
      case AppAccountSignedIn(:final account):
        _pending = null;
        _account = account;
        _checkedAt = _now();
        notifyListeners();
        // 中转刚用这个账号登录过教务，本机的会话已被挤掉：紧接着自己重登，换上新会话。
        final refreshed = await accounts.refreshSession(password: pending.password);
        if (!refreshed.ok) campusLog('[AppAccounts] action=refresh_session code=${refreshed.error?.code}');
        return AppAccountDone(refreshed.ok ? '已登录应用账号' : '已登录应用账号；教务需要重新登录一次');
    }
  }

  Future<AppAccountResult> signOut() => _run('sign_out', () async {
    final identity = _identity;
    if (identity == null || _account == null) return const AppAccountDone();
    await client.signOut(identity);
    if (_same(identity, _identity)) _account = null;
    return const AppAccountDone('已退出应用账号');
  });

  // 注销：服务端删掉账号与全部设备上的登录，本机随之退出。
  Future<AppAccountResult> deleteAccount() => _run('delete', () async {
    final identity = _identity;
    if (identity == null || _account == null) return const AppAccountDone();
    try {
      await client.delete(identity);
    } on AppAccountException catch (error) {
      return AppAccountError(error.message);
    }
    if (_same(identity, _identity)) _account = null;
    return const AppAccountDone('应用账号已注销');
  });

  // 退出教务时跟着退出这个教务账号的应用账号（组合根接线）：退出本身不经页面，失败只记日志。
  Future<void> forget(AccountIdentity identity) async {
    try {
      await client.signOut(identity);
    } catch (error, stack) {
      campusLog('[AppAccounts] action=forget errorType=${error.runtimeType}\n$stack');
    }
    if (_same(identity, _identity) && _account != null) {
      _account = null;
      notifyListeners();
    }
  }

  // 启动（同意协议与政策之后）与回到前台时由组合根调：登录着且距上次超过 checkGap 才联网看一眼；账号已在别处注销或被清理就退回未登录。
  // force：挑战或积分那边中转说这个应用账号已不在了，不等间隔马上核一次。
  Future<void> check({bool force = false}) async {
    final identity = _identity;
    final checkedAt = _checkedAt;
    if (identity == null || _account == null || _busy || (!force && checkedAt != null && _now().difference(checkedAt) < checkGap)) return;
    _checkedAt = _now();
    try {
      await client.summary(identity);
    } on AppAccountException catch (error) {
      campusLog('[AppAccounts] action=check failure=${error.failure.name}');
      if (error.failure == AppAccountFailure.notSignedIn && _same(identity, _identity)) {
        _account = null;
        notifyListeners();
      }
    } catch (error, stack) {
      campusLog('[AppAccounts] action=check errorType=${error.runtimeType}\n$stack');
    }
  }

  @override
  void dispose() {
    accounts.removeListener(_accountsChanged);
    _cancelPending();
    super.dispose();
  }
}
