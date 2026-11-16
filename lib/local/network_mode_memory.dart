import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/network_policy.dart';

// 联网偏好的本机记录（人工决策见 domain/network_policy.dart 的 11-16 22:24:59 那条）：应用支持目录下固定大小的 network_mode.json，属于设备，切换账号保留。
// 先写临时文件再改名、写入排队；没有文件或读到坏文件当联网化（默认）。只是一项偏好，不排除出云备份。
class FileNetworkModeMemory implements NetworkModeMemory {
  FileNetworkModeMemory._(this._file, this._mode);
  final File? _file;
  NetworkMode _mode;
  final _saveLock = Lock();

  static Future<FileNetworkModeMemory> open(File file) async {
    if (!await file.exists()) return FileNetworkModeMemory._(file, NetworkMode.online);
    try {
      final json = jsonDecode(await file.readAsString());
      return FileNetworkModeMemory._(file, json is Map && json['mode'] == NetworkMode.local.name ? NetworkMode.local : NetworkMode.online);
    } catch (error, stack) {
      campusLog('[NetworkMode] action=read errorType=${error.runtimeType}\n$stack');
      return FileNetworkModeMemory._(file, NetworkMode.online);
    }
  }

  // 测试用：只在内存里。
  FileNetworkModeMemory.memory({NetworkMode mode = NetworkMode.online}) : this._(null, mode);

  @override
  NetworkMode get mode => _mode;

  @override
  Future<void> saveMode(NetworkMode mode) {
    _mode = mode;
    return _saveLock.synchronized(() async {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.tmp');
      await pending.writeAsString(jsonEncode({'mode': mode.name}), flush: true);
      await pending.rename(file.path);
    });
  }
}
