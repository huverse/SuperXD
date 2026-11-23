import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/quick_nav.dart';

// 侧栏常用与最近的本机记录（规则见 domain/quick_nav.dart）：应用支持目录下的 quick_nav.json，属于设备，切换账号保留。
// 先写临时文件再改名、写入排队；没有文件或读到坏文件当没有记录（常用用默认、最近为空）。大小有界（常用随入口目录封顶、最近 5 个），只是偏好，不排除出云备份。
class FileQuickNavMemory implements QuickNavMemory {
  FileQuickNavMemory._(this._file, this._prefs);
  final File? _file;
  QuickNavPrefs _prefs;
  final _saveLock = Lock();

  static Future<FileQuickNavMemory> open(File file) async {
    if (!await file.exists()) return FileQuickNavMemory._(file, const QuickNavPrefs());
    try {
      return FileQuickNavMemory._(file, QuickNavPrefs.fromJson(jsonDecode(await file.readAsString())));
    } catch (error, stack) {
      campusLog('[QuickNav] action=read errorType=${error.runtimeType}\n$stack');
      return FileQuickNavMemory._(file, const QuickNavPrefs());
    }
  }

  // 测试用：只在内存里。
  FileQuickNavMemory.memory([QuickNavPrefs prefs = const QuickNavPrefs()]) : this._(null, prefs);

  @override
  QuickNavPrefs get prefs => _prefs;

  @override
  Future<void> save(QuickNavPrefs prefs) {
    _prefs = prefs;
    return _saveLock.synchronized(() async {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.tmp');
      await pending.writeAsString(jsonEncode(_prefs.toJson()), flush: true);
      await pending.rename(file.path);
    });
  }
}
