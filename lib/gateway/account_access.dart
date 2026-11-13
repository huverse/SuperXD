import 'package:flutter/foundation.dart';

import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/gateway_code.dart';

// 账号生命周期属于应用层；页面不感知 SQLite 路径、教务客户端或 cookie。
abstract class AccountAccess extends ChangeNotifier implements CampusGateway {
  int get generation;
  SessionView? get activeSession;
  AccountIdentity? get activeIdentity;
  // 学期、课表、作息、开学日或提醒设置在本机写入成功后通知；课前提醒据此重新对账。
  Listenable get scheduleChanges => const _NoChanges();
  Future<GatewayResult<LoginView>> loginRemembered(String account, String password, {required bool remember}) => login(account, password);
  Future<bool> isRemembered() async => false;
  // 已登录时用密码核对一次（要验证码时经 submitLoginCaptcha 接着交）后开启记住账号，不切换当前会话。
  Future<GatewayResult<LoginView>> rememberWithPassword(String password) async => const GatewayResult(
    ok: false,
    source: 'local',
    fetchedAt: '',
    error: GatewayError(code: GatewayCode.operationFailed, message: '这里不能开启记住账号'),
  );
  Future<void> forgetCredential() async {}
  // 应用账号核对用的口令摘要（人工决策见 domain/app_account.dart）：给了密码用它，没给用记住的；都没有报 PASSWORD_NEEDED。不联网。
  Future<GatewayResult<KingoSignInProof>> appAccountProof({String? password}) async => const GatewayResult(
    ok: false,
    source: 'local',
    fetchedAt: '',
    error: GatewayError(code: GatewayCode.operationFailed, message: '这里不能登录应用账号'),
  );
  // 中转代登录会挤掉本机的教务会话：用给的密码（没给用记住的）为当前账号重登一次，换上新会话，不换代次、页面不动。
  Future<GatewayResult<bool>> refreshSession({String? password}) async => const GatewayResult(
    ok: false,
    source: 'local',
    fetchedAt: '',
    error: GatewayError(code: GatewayCode.operationFailed, message: '这里不能重新登录'),
  );
  // 用户主动退出某个账号（不含会话过期）时发出这个账号；应用账号跟着退出（组合根接线）。
  Stream<AccountIdentity> get loggedOut => const Stream.empty();
  Future<void> expireSession() => logout();
  String? takeAccountNotice() => null;
  Future<void> cancelLogin();
  Future<void> logout();
  Future<LegacyImportState> legacyImportState();
  Future<void> deferLegacyImport();
  Future<GatewayResult<LegacyImportReport>> importLegacy();
  Future<void> close();
}

class _NoChanges implements Listenable {
  const _NoChanges();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}
