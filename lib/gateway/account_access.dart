import 'package:flutter/foundation.dart';

import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/campus_gateway.dart';

// 账号生命周期属于应用层；页面不感知 SQLite 路径、教务客户端或 cookie。
abstract class AccountAccess extends ChangeNotifier implements CampusGateway {
  int get generation;
  SessionView? get activeSession;
  AccountIdentity? get activeIdentity;
  Future<GatewayResult<LoginView>> loginRemembered(String account, String password, {required bool remember}) => login(account, password);
  Future<bool> isRemembered() async => false;
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
