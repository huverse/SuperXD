import 'package:flutter/foundation.dart';

import 'package:superxd/domain/account.dart';
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
