import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/network_policy.dart';

// 联网偏好的本机记录（人工决策见 domain/network_policy.dart 的 11-16 22:24:59 那条）：应用支持目录下固定大小的 network_mode.json，属于设备，切换账号保留。
// 先写临时文件再改名、写入排队；没有文件或读到坏文件当联网（默认）。只是一项偏好，不排除出云备份。
// [人工决策-2026-11-17 14:17:05] 用户选定：以前在「我的」里关过「游乐场与积分」（旧的 leisure.json 写着关）的老用户，升级后改为本地化（可在应用账号页改回），
// 取代 11-16 「不迁移、一律回到联网化」的默认。只在还没有 network_mode.json 时看一次 legacy：迁移结果当场写进 network_mode.json，再删掉旧文件。
class FileNetworkModeMemory implements NetworkModeMemory {
  FileNetworkModeMemory._(this._file, this._mode);
  final File? _file;
  NetworkMode _mode;
  final _saveLock = Lock();

  static Future<FileNetworkModeMemory> open(File file, {File? legacy}) async {
    if (!await file.exists()) {
      final memory = FileNetworkModeMemory._(file, NetworkMode.online);
      if (legacy != null && await _leisureWasOff(legacy)) {
        await memory.saveMode(NetworkMode.local);
        campusLog('[NetworkMode] action=migrate from=leisure mode=local');
      }
      if (legacy != null && await legacy.exists()) await legacy.delete();
      return memory;
    }
    try {
      final json = jsonDecode(await file.readAsString());
      return FileNetworkModeMemory._(file, json is Map && json['mode'] == NetworkMode.local.name ? NetworkMode.local : NetworkMode.online);
    } catch (error, stack) {
      campusLog('[NetworkMode] action=read errorType=${error.runtimeType}\n$stack');
      return FileNetworkModeMemory._(file, NetworkMode.online);
    }
  }

  // 旧的娱乐与积分开关：写着 enabled 为 false 才算关过；没有文件或坏文件当没关过。
  static Future<bool> _leisureWasOff(File legacy) async {
    if (!await legacy.exists()) return false;
    try {
      final json = jsonDecode(await legacy.readAsString());
      return json is Map && json['enabled'] == false;
    } catch (error, stack) {
      campusLog('[NetworkMode] action=read_legacy errorType=${error.runtimeType}\n$stack');
      return false;
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
