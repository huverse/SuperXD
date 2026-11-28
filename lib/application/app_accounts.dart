import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';

// 页面发起一次应用账号操作的结果：做完了（可带一句提示）、做完了且有新的恢复码要给用户抄下、出示了扫码登录的二维码、还在等批准、或失败（原因给用户看）。
sealed class AppAccountResult {
  const AppAccountResult();
}

final class AppAccountDone extends AppAccountResult {
  const AppAccountDone([this.notice]);
  final String? notice;
}

final class AppAccountRecoveryCode extends AppAccountResult {
  const AppAccountRecoveryCode(this.code, this.notice);
  // 不带分隔符的规范写法，页面按 formatRecoveryCode 分组显示。
  final String code;
  final String notice;
}

final class AppAccountJoinStarted extends AppAccountResult {
  const AppAccountJoinStarted(this.join);
  final AppAccountJoin join;
}

final class AppAccountWaiting extends AppAccountResult {
  const AppAccountWaiting();
}

// 批准方批准前看到的请求方（机型与属地）。
final class AppAccountJoinRequested extends AppAccountResult {
  const AppAccountJoinRequested(this.request);
  final AppAccountJoinRequest request;
}

final class AppAccountError extends AppAccountResult {
  const AppAccountError(this.message);
  final String message;
}

// 应用账号的编排（设备级，人工决策见 domain/app_account.dart 的 11-15 16:40:33 那条）：这台设备一个应用账号，与教务各管各的
// （取代 11-13 的「跟着教务走」：切换、退出教务都不影响它，没登录教务也能登录）。用户名加密码注册与登录，恢复码在这里生成、原文只交给页面显示一次；
// 忘了密码凭恢复码重设，或在登录着的这台上直接改。扫码登录给新设备免输密码。
class AppAccounts extends ChangeNotifier {
  AppAccounts({required this.client, this.onDeleted, DateTime Function()? now, String Function()? recoveryCode})
    : _now = now ?? DateTime.now,
      _recoveryCode = recoveryCode ?? generateRecoveryCode;
  final AppAccountClient client;
  // 注销成功后（服务器已删掉账号下的数据）、中转说账号已在别处注销时，以及清掉 11-15 以前的旧账号时：
  // 组合根接上清掉这台手机上那个账号的私信（人工决策见 social/social_service.dart 与 domain/app_account.dart 的 19:18:31 那条）。
  final void Function(AppAccountRef account)? onDeleted;
  final DateTime Function() _now;
  final String Function() _recoveryCode;

  // 联网看账号（顺带让服务器记最后活跃、发现别处注销）至少隔这么久：账号 400 天没查看才会被清，一天一次足够。
  static const checkGap = Duration(hours: 24);

  AppAccountSession? _session;
  bool _loaded = false;
  bool _busy = false;
  DateTime? _checkedAt;

  // 当前的应用账号（人工决策见 domain/app_account.dart 的 AppAccountRef）：挑战、节日抽奖、诊断包、私信都只认它；没登录为空。
  AppAccountRef? get current => _session?.account;
  // 它的账号号（灰度与分批更新按它分桶）。
  String? get accountId => _session?.account.accountId;
  String? get username => _session?.username;
  bool get loaded => _loaded;
  bool get busy => _busy;

  // 启动时读本机记着的应用账号（不联网）；先清掉 11-15 以前每个教务账号一把的旧密钥（老账号全部重新注册，用户选），连带它们的本机私信。
  // 安全存储出错或记录认不出时当没登录、照样读完（不然账号页那一行一直灰着、私信一直停在读取中），重新登录会覆盖那条记录；清旧密钥出错下次启动再清。
  Future<void> load() async {
    try {
      for (final legacy in await client.dropLegacy()) {
        campusLog('[AppAccounts] action=drop_legacy');
        onDeleted?.call(legacy);
      }
    } catch (error, stack) {
      campusLog('[AppAccounts] action=drop_legacy errorType=${error.runtimeType}\n$stack');
    }
    try {
      _session = await client.accountOf();
    } catch (error, stack) {
      campusLog('[AppAccounts] action=load errorType=${error.runtimeType}\n$stack');
      _session = null;
    }
    _loaded = true;
    _checkedAt = null;
    notifyListeners();
  }

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
      lost = (error.failure == AppAccountFailure.notSignedIn || error.failure == AppAccountFailure.deleted) && _session != null;
      return AppAccountError(error.message);
    } catch (error, stack) {
      campusLog('[AppAccounts] action=$action errorType=${error.runtimeType}\n$stack');
      return const AppAccountError('应用账号操作没有完成，请重试');
    } finally {
      _busy = false;
      notifyListeners();
      // 中转说这台设备已不在账号里（被顶掉、重设踢下线、别处注销）：马上核一次，本机退回未登录，账号已注销的另清本机私信。
      if (lost) unawaited(check(force: true));
    }
  }

  void _signedIn(AppAccountSession session) {
    _session = session;
    _checkedAt = _now();
    notifyListeners();
  }

  // 注册：恢复码在这里生成，成功后交给页面显示一次（让用户抄下）。
  Future<AppAccountResult> register(String username, String password) => _run('register', () async {
    final code = _recoveryCode();
    _signedIn(await client.register(username, password, code));
    return AppAccountRecoveryCode(code, '已注册并登录');
  });

  Future<AppAccountResult> login(String username, String password) => _run('login', () async {
    _signedIn(await client.login(username, password));
    return const AppAccountDone('已登录应用账号');
  });

  // 忘了密码：凭恢复码设新密码，旧恢复码作废、换成新的（交给页面显示一次）。
  Future<AppAccountResult> recover(String username, String recoveryCode, String password) => _run('recover', () async {
    final code = normalizeRecoveryCode(recoveryCode);
    if (code == null) return const AppAccountError('恢复码不对');
    final next = _recoveryCode();
    try {
      _signedIn(await client.recover(username, code, password, next));
    } on AppAccountException catch (error) {
      // 服务器不说是哪一项不对；这里交的是恢复码，提示照实写。
      if (error.failure == AppAccountFailure.credentialsInvalid) return const AppAccountError('用户名或恢复码不对');
      rethrow;
    }
    return AppAccountRecoveryCode(next, '已重设密码并登录');
  });

  Future<AppAccountResult> changePassword(String password) => _run('change_password', () async {
    if (_session == null) return const AppAccountError('没有登录应用账号');
    await client.changePassword(password);
    return const AppAccountDone('已修改密码');
  });

  // 换一个新的恢复码（旧的作废），交给页面显示一次。
  Future<AppAccountResult> renewRecoveryCode() => _run('renew_recovery', () async {
    if (_session == null) return const AppAccountError('没有登录应用账号');
    final code = _recoveryCode();
    await client.changeRecoveryCode(code);
    return AppAccountRecoveryCode(code, '已换新的恢复码');
  });

  // 扫码登录，新设备这一侧：出示二维码。
  Future<AppAccountResult> startJoin() => _run('start_join', () async => AppAccountJoinStarted(await client.startJoin()));

  // 出示二维码时页面定时问一次批准了没有；连不上照旧等（不打断出示），过期或不对就报错。不占 busy，不挡别的操作。
  Future<AppAccountResult> pollJoin(AppAccountJoin join) async {
    try {
      final session = await client.joinState(join);
      if (session == null) return const AppAccountWaiting();
      campusLog('[AppAccounts] action=join result=approved');
      _signedIn(session);
      return const AppAccountDone('已登录应用账号');
    } on AppAccountException catch (error) {
      campusLog('[AppAccounts] action=poll_join failure=${error.failure.name}');
      return error.failure == AppAccountFailure.network ? const AppAccountWaiting() : AppAccountError(error.message);
    } catch (error, stack) {
      campusLog('[AppAccounts] action=poll_join errorType=${error.runtimeType}\n$stack');
      return const AppAccountError('应用账号操作没有完成，请重试');
    }
  }

  // 离开出示页（或刷新二维码换下旧的那张）时作废票据：不等、不占 busy，失败只记日志（票据 5 分钟后自己过期）。
  Future<void> cancelJoin(AppAccountJoin join) async {
    try {
      await client.cancelJoin(join);
    } catch (error, stack) {
      campusLog('[AppAccounts] action=cancel_join errorType=${error.runtimeType}\n$stack');
    }
  }

  // 登录着的设备批准前先看请求方（机型与属地），页面写进确认框（人工决策见 domain/app_account.dart 的 19:18:31 那条）。
  Future<AppAccountResult> inspectJoin(String payload) => _run('inspect_join', () async {
    if (_session == null) return const AppAccountError('没有登录应用账号');
    return AppAccountJoinRequested(await client.inspectJoin(payload));
  });

  // 登录着的设备批准扫到的登录码（页面已请用户核对过 6 位码与请求方）。
  Future<AppAccountResult> approveJoin(String payload) => _run('approve_join', () async {
    if (_session == null) return const AppAccountError('没有登录应用账号');
    await client.approveJoin(payload);
    return const AppAccountDone('已让新设备登录');
  });

  Future<AppAccountResult> signOut() => _run('sign_out', () async {
    if (_session == null) return const AppAccountDone();
    await client.signOut();
    _session = null;
    return const AppAccountDone('已退出应用账号');
  });

  // 注销：服务端删掉账号与全部设备上的登录，本机随之退出。
  Future<AppAccountResult> deleteAccount() => _run('delete', () async {
    final session = _session;
    if (session == null) return const AppAccountDone();
    await client.delete();
    onDeleted?.call(session.account);
    _session = null;
    return const AppAccountDone('应用账号已注销');
  });

  // 启动（同意协议与政策之后）与回到前台时由组合根调：登录着且距上次超过 checkGap 才联网看一眼；这把密钥已不在账号里就退回未登录，账号已注销的另交给 onDeleted。
  // force：挑战或积分那边中转说这个应用账号已不在了，不等间隔马上核一次。
  Future<void> check({bool force = false}) async {
    final session = _session, checkedAt = _checkedAt;
    if (session == null || _busy || (!force && checkedAt != null && _now().difference(checkedAt) < checkGap)) return;
    _checkedAt = _now();
    try {
      final summary = await client.summary();
      // 用户名以服务器为准（换手机登录时写进本机的就是它，这里只是顺带对一下）。
      if (identical(_session, session) && summary.username != session.username) {
        _session = AppAccountSession(account: session.account, username: summary.username);
        notifyListeners();
      }
    } on AppAccountException catch (error) {
      campusLog('[AppAccounts] action=check failure=${error.failure.name}');
      final gone = error.failure == AppAccountFailure.notSignedIn || error.failure == AppAccountFailure.deleted;
      // 这一问在路上时已经换成了别的账号：只是当前账号不跟着退回未登录（11-28 复核 F03）。
      if (gone && identical(_session, session)) {
        _session = null;
        notifyListeners();
      }
      // 只有账号已注销才清本机那个账号的私信；被顶掉、重设踢下线的再登录还能接着用（人工决策见 domain/app_account.dart 的 19:18:31 那条）。
      // 注销带服务器签名才认（RelayClient），换了账号也照样清被注销的那个账号的（原来换了账号就漏清，那个账号再也登不上、私信一直留在手机上）。
      if (error.failure == AppAccountFailure.deleted) onDeleted?.call(session.account);
    } catch (error, stack) {
      campusLog('[AppAccounts] action=check errorType=${error.runtimeType}\n$stack');
    }
  }
}
