import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';

// 开发者模式与它下面的调试开关：应用支持目录下固定大小的 developer.json，属于设备，切换账号保留。
// 先写临时文件再改名；读到坏文件当都关着。开发者模式只多记日志、多给调试工具，不改任何业务行为。
class DeveloperSettings extends ChangeNotifier {
  DeveloperSettings._(this._file, this._enabled, this._performanceOverlay);
  final File? _file;
  bool _enabled;
  bool _performanceOverlay;

  static Future<DeveloperSettings> open(File file) async {
    if (!await file.exists()) return DeveloperSettings._(file, false, false);
    try {
      final json = jsonDecode(await file.readAsString());
      bool flag(String key) => json is Map && json[key] == true;
      return DeveloperSettings._(file, flag('enabled'), flag('enabled') && flag('performanceOverlay'));
    } catch (error, stack) {
      campusLog('[Developer] action=settings_read errorType=${error.runtimeType}\n$stack');
      return DeveloperSettings._(file, false, false);
    }
  }

  // 测试用：只在内存里。
  DeveloperSettings.memory({bool enabled = false, bool performanceOverlay = false}) : this._(null, enabled, performanceOverlay);

  bool get enabled => _enabled;
  // 性能浮层（Flutter 的帧耗时图）：只在开发者模式下有效，关掉开发者模式时一起关。
  bool get performanceOverlay => _performanceOverlay;

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    if (!value) _performanceOverlay = false;
    notifyListeners();
    await _write();
  }

  Future<void> setPerformanceOverlay(bool value) async {
    _performanceOverlay = value && _enabled;
    notifyListeners();
    await _write();
  }

  Future<void> _write() async {
    final file = _file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(jsonEncode({'enabled': _enabled, 'performanceOverlay': _performanceOverlay}), flush: true);
    await pending.rename(file.path);
  }
}
