import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/quick_nav.dart';

// 侧栏的常用与最近 QuickNav（设备级，规则见 domain/quick_nav.dart）：侧栏与编辑页读写，组合根在进了登记的入口时记最近；变了通知。不认识具体页面。
class QuickNav extends ChangeNotifier {
  QuickNav({required this.memory});
  final QuickNavMemory memory;

  QuickNavPrefs get prefs => memory.prefs;

  // 进了一个入口：记进最近（已在最前就不写）。热路径上不等写盘，写不成只记日志。
  void visit(String id) {
    if (prefs.recent.firstOrNull == id) return;
    _save(prefs.visited(id)).catchError((Object error, StackTrace stack) => campusLog('[QuickNav] action=visit errorType=${error.runtimeType}\n$stack'));
  }

  // 编辑页点了就存：先通知界面，再等写盘。
  Future<void> pin(List<String> ids) => _save(prefs.pinning(ids));

  Future<void> _save(QuickNavPrefs next) {
    final saving = memory.save(next);
    notifyListeners();
    return saving;
  }
}
