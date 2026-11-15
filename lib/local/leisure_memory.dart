import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/leisure.dart';

// 娱乐与积分的开关（人工决策见 domain/leisure.dart）：应用支持目录下固定大小的 leisure.json，属于设备，切换账号保留。
// 先写临时文件再改名、写入排队；没有文件或读到坏文件当打开着（默认打开）。只是一项偏好，不排除出云备份。
class FileLeisureMemory implements LeisureMemory {
  FileLeisureMemory._(this._file, this._enabled);
  final File? _file;
  bool _enabled;
  final _saveLock = Lock();

  static Future<FileLeisureMemory> open(File file) async {
    if (!await file.exists()) return FileLeisureMemory._(file, true);
    try {
      final json = jsonDecode(await file.readAsString());
      return FileLeisureMemory._(file, !(json is Map && json['enabled'] == false));
    } catch (error, stack) {
      campusLog('[Leisure] action=read errorType=${error.runtimeType}\n$stack');
      return FileLeisureMemory._(file, true);
    }
  }

  // 测试用：只在内存里。
  FileLeisureMemory.memory({bool enabled = true}) : this._(null, enabled);

  @override
  bool get enabled => _enabled;

  @override
  Future<void> saveEnabled(bool value) {
    _enabled = value;
    return _saveLock.synchronized(() async {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.tmp');
      await pending.writeAsString(jsonEncode({'enabled': _enabled}), flush: true);
      await pending.rename(file.path);
    });
  }
}
