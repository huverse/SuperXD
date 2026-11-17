import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';

// 游乐场与积分的「删除数据」（设备级，人工决策见 domain/leisure.dart；11-16 起开关并进联网偏好，这里只管删除）：
// 登录着应用账号时先删服务器上的（deleteRemote，失败照原样抛出、本机不动，免得只删了一半），再清本机（clearLocal：游乐场成绩与笔记、记着的等级）。
// 两者都由组合根注入（服务器那一步是挑战与积分的签名请求），这里不认识游乐场、挑战与灰度。
class Leisure extends ChangeNotifier {
  Leisure({required this._clearLocal, this._deleteRemote, bool Function()? signedIn}) : _signedIn = signedIn ?? (() => false);
  final Future<void> Function() _clearLocal;
  // 没配中转时为空：只清本机。
  final Future<void> Function()? _deleteRemote;
  final bool Function() _signedIn;

  // 删除数据时会连服务器上的一起删（配了中转、登录着应用账号、联网化）。
  bool get signedIn => _deleteRemote != null && _signedIn();

  // 返回服务器上的有没有一起删。
  Future<bool> deleteData() async {
    final remote = signedIn;
    if (remote) await _deleteRemote!();
    await _clearLocal();
    campusLog('[Leisure] action=delete remote=$remote');
    notifyListeners();
    return remote;
  }
}
