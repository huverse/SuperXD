import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/rollout.dart';

// 灰度的本机记录（人工决策见 domain/rollout.dart）：rollout.json 里是这台设备的随机编号（没登录应用账号时分桶用，只在本机、不上传）、
// 上次拉到的配置，与当前主体的积分等级和只因等级进的批次；先写临时文件再改名，坏文件当没有（编号重新生成，最多换一次桶）。
// 只有一份配置、批次最多 rolloutRuleLimit 个，不随使用增长。
class FileRolloutMemory implements RolloutMemory {
  FileRolloutMemory._(this._file, this.installId, this._config, this._fetchedAt, [this._subject, this._level = 0, List<String> joined = const []]) : _joined = [...joined];
  final File? _file;
  @override
  final String installId;
  RolloutConfig _config;
  DateTime? _fetchedAt;
  String? _subject;
  int _level;
  final List<String> _joined;
  final _lock = Lock();

  static Future<FileRolloutMemory> open(File file) async {
    try {
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json case {'installId': final String installId, 'config': final Object? config} when tryDecodeBase64UrlNoPad(installId, length: 16) != null) {
          final fetchedAt = json['fetchedAt'] is String ? DateTime.tryParse(json['fetchedAt'] as String)?.toUtc() : null;
          // 等级与批次只认格式对的，不对就当没记过（只影响加权，下次联网再取）。
          if (json case {'subject': final String subject, 'level': final int level, 'joined': final List<Object?> joined}
              when level >= 0 && level < pointsLevelCount && joined.length <= rolloutRuleLimit && joined.every((id) => id is String && rolloutIdPattern.hasMatch(id))) {
            return FileRolloutMemory._(file, installId, decodeRolloutConfig(config), fetchedAt, subject, level, joined.cast<String>());
          }
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

  @override
  int levelOf(String subject) => subject == _subject ? _level : 0;

  @override
  bool joined(String subject, String id) => subject == _subject && _joined.contains(id);

  // 换了主体：等级与批次都从头记。
  void _switchTo(String subject) {
    if (subject == _subject) return;
    _subject = subject;
    _level = 0;
    _joined.clear();
  }

  @override
  Future<void> saveLevel(String subject, int level) {
    _switchTo(subject);
    if (level == _level) return Future.value();
    _level = level;
    return _write();
  }

  @override
  Future<void> join(String subject, String id) {
    _switchTo(subject);
    if (_joined.contains(id)) return Future.value();
    _joined.add(id);
    if (_joined.length > rolloutRuleLimit) _joined.removeAt(0);
    return _write();
  }

  Future<void> _write() {
    final snapshot = {
      'installId': installId,
      'config': encodeRolloutConfig(_config),
      if (_fetchedAt case final at?) 'fetchedAt': at.toIso8601String(),
      if (_subject case final subject?) ...{'subject': subject, 'level': _level, 'joined': [..._joined]},
    };
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
