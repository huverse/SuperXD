import 'dart:convert';
import 'dart:io';

import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/campus_log.dart';

// 自动检查更新的记录：应用支持目录下一个固定大小的 JSON（上次查成功的时刻 UTC、跳过的版本、是否待必须更新），属于设备，切换账号保留。
// 先写临时文件再改名，写到一半断电不留半截；读到坏文件当没有记录（大不了今天多查一次）。
class FileAppUpdateMemory implements AppUpdateMemory {
  FileAppUpdateMemory._(this._file, this._lastCheckedAt, this._skippedVersionCode, this._forcedPending);
  final File? _file;
  DateTime? _lastCheckedAt;
  int? _skippedVersionCode;
  bool _forcedPending;

  static Future<FileAppUpdateMemory> open(File file) async {
    if (!await file.exists()) return FileAppUpdateMemory._(file, null, null, false);
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) throw const FormatException('不是对象');
      return FileAppUpdateMemory._(
        file,
        switch (json['lastCheckedAt']) {
          final String value => DateTime.tryParse(value)?.toUtc(),
          _ => null,
        },
        switch (json['skippedVersionCode']) {
          final int value => value,
          _ => null,
        },
        json['forcedPending'] == true,
      );
    } catch (error, stack) {
      campusLog('[AppUpdate] action=memory_read errorType=${error.runtimeType}\n$stack');
      return FileAppUpdateMemory._(file, null, null, false);
    }
  }

  // 测试用：只在内存里。
  FileAppUpdateMemory.memory() : this._(null, null, null, false);

  @override
  DateTime? get lastCheckedAt => _lastCheckedAt;
  @override
  int? get skippedVersionCode => _skippedVersionCode;
  @override
  bool get forcedPending => _forcedPending;

  @override
  Future<void> save({required DateTime? lastCheckedAt, required int? skippedVersionCode, required bool forcedPending}) async {
    _lastCheckedAt = lastCheckedAt?.toUtc();
    _skippedVersionCode = skippedVersionCode;
    _forcedPending = forcedPending;
    final file = _file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(jsonEncode({'lastCheckedAt': _lastCheckedAt?.toIso8601String(), 'skippedVersionCode': _skippedVersionCode, 'forcedPending': _forcedPending}), flush: true);
    await pending.rename(file.path);
  }
}
