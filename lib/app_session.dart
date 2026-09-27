import 'package:flutter/foundation.dart';

import 'package:superxd/gateway/account_access.dart';

class AppSession extends ChangeNotifier {
  AppSession(this.gateway) {
    gateway.addListener(_accountChanged);
  }
  final AccountAccess gateway;
  bool ready = false;
  String? pendingNotice;

  Future<void> importLegacy() async {
    final result = await gateway.importLegacy();
    if (!result.ok || result.data == null) {
      pendingNotice = result.error?.message ?? '导入未完成，原数据保留，可重试。';
    } else {
      final report = result.data!;
      pendingNotice = report.alreadyImported ? '这份旧数据已经导入，无需重复操作。' : '已导入 ${report.imported} 项，保留或跳过 ${report.skipped} 项。原库未删除。';
    }
    notifyListeners();
  }

  String? takeNotice() {
    final message = pendingNotice;
    pendingNotice = null;
    return message;
  }
  int get generation => gateway.generation;
  bool get loggedIn => gateway.activeSession != null;

  Future<void> restore() async {
    try {
      await gateway.restoreSession();
    } finally {
      pendingNotice = gateway.takeAccountNotice() ?? pendingNotice;
      ready = true;
      notifyListeners();
    }
  }

  void _accountChanged() {
    pendingNotice = gateway.takeAccountNotice() ?? pendingNotice;
    notifyListeners();
  }

  Future<void> expire(int expectedGeneration) async {
    if (expectedGeneration != generation) return;
    await gateway.expireSession();
  }

  @override
  void dispose() {
    gateway.removeListener(_accountChanged);
    super.dispose();
  }
}
