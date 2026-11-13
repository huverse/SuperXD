import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/rollout.dart';

// 灰度的本机记录（人工决策见 domain/rollout.dart）：rollout.json 里是这台设备的随机编号（没登录应用账号时分桶用，只在本机、不上传）
// 与上次拉到的配置；先写临时文件再改名，坏文件当没有（编号重新生成，最多换一次桶）。只有一份配置，不随使用增长。
class FileRolloutMemory implements RolloutMemory {
  FileRolloutMemory._(this._file, this.installId, this._config, this._fetchedAt);
  final File? _file;
  @override
  final String installId;
  RolloutConfig _config;
  DateTime? _fetchedAt;
  final _lock = Lock();

  static Future<FileRolloutMemory> open(File file) async {
    try {
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json case {'installId': final String installId, 'config': final Object? config} when tryDecodeBase64UrlNoPad(installId, length: 16) != null) {
          final fetchedAt = json['fetchedAt'] is String ? DateTime.tryParse(json['fetchedAt'] as String)?.toUtc() : null;
          return FileRolloutMemory._(file, installId, decodeRolloutConfig(config), fetchedAt);
        }
      }
    } catch (error, stack) {
      campusLog('[Rollouts] action=memory_read errorType=${error.runtimeType}\n$stack');
    }
    final memory = FileRolloutMemory._(file, base64UrlNoPad(secureRandomBytes(16)), RolloutConfig.empty, null);
    await memory._write();
    return memory;
  }

  // 测试用：只在内存里。
  FileRolloutMemory.memory({String installId = 'AAAAAAAAAAAAAAAAAAAAAA', RolloutConfig config = RolloutConfig.empty, DateTime? fetchedAt}) : this._(null, installId, config, fetchedAt);

  @override
  RolloutConfig get config => _config;

  @override
  DateTime? get fetchedAt => _fetchedAt;

  @override
  Future<void> save(RolloutConfig config, DateTime fetchedAt) {
    _config = config;
    _fetchedAt = fetchedAt.toUtc();
    return _write();
  }

  Future<void> _write() {
    final snapshot = {'installId': installId, 'config': encodeRolloutConfig(_config), if (_fetchedAt case final at?) 'fetchedAt': at.toIso8601String()};
    return _lock.synchronized(() async {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.tmp');
      await pending.writeAsString(jsonEncode(snapshot), flush: true);
      await pending.rename(file.path);
    });
  }
}
