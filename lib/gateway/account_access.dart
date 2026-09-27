import 'package:flutter/foundation.dart';

import 'package:superxd/gateway/campus_gateway.dart';

class AccountIdentity {
  const AccountIdentity({required this.source, required this.loginId});
  final String source;
  final String loginId;
}

class LegacyImportState {
  const LegacyImportState({required this.available, this.deferred = false, this.resumable = false});
  final bool available;
  final bool deferred;
  final bool resumable;
}

class LegacyImportReport {
  const LegacyImportReport({required this.imported, required this.skipped, this.alreadyImported = false});
  final int imported;
  final int skipped;
  final bool alreadyImported;
}

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
