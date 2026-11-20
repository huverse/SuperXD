import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/rollout.dart';

// 灰度的本机记录（人工决策见 domain/rollout.dart）：rollout.json 里是这台设备的随机编号（没登录应用账号时分桶用，只在本机、不上传）、
// 上次拉到的配置，与当前主体的积分等级和只因等级进的批次；先写临时文件再改名，坏文件当没有（编号重新生成，最多换一次桶）。
// 另记当前主体问到的点名与账号建立的时刻（11-16 起），以及配置与点名的版本号（11-20 起，条件请求用，人工决策见 domain/rollout.dart 的 RolloutSignals）。
// 只有一份配置、批次与点名各最多 rolloutRuleLimit 个，不随使用增长。
class FileRolloutMemory implements RolloutMemory {
  FileRolloutMemory._(this._file, this.installId, this._config, this._fetchedAt, this._etag, [this._subject, this._level = 0, List<String> joined = const [], RolloutTargets? targets, this._targetsEtag])
    : _joined = [...joined],
      _targets = [...?targets?.flags],
      _accountCreatedAt = targets?.accountCreatedAt;
  final File? _file;
  @override
  final String installId;
  RolloutConfig _config;
  DateTime? _fetchedAt;
  String? _etag;
  String? _subject;
  int _level;
  final List<String> _joined;
  // 当前主体问到的点名（最多 rolloutTargetLimit 个，服务器给的就有上限）。
  final List<RolloutTarget> _targets;
  DateTime? _accountCreatedAt;
  String? _targetsEtag;
  final _lock = Lock();

  static Future<FileRolloutMemory> open(File file) async {
    try {
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json case {'installId': final String installId, 'config': final Object? config} when tryDecodeBase64UrlNoPad(installId, length: 16) != null) {
          final fetchedAt = json['fetchedAt'] is String ? DateTime.tryParse(json['fetchedAt'] as String)?.toUtc() : null;
          final etag = _etagOf(json['etag']);
          // 等级与批次只认格式对的，不对就当没记过（只影响加权，下次联网再取）。
          if (json case {'subject': final String subject, 'level': final int level, 'joined': final List<Object?> joined}
              when level >= 0 && level < pointsLevelCount && joined.length <= rolloutRuleLimit && joined.every((id) => id is String && rolloutIdPattern.hasMatch(id))) {
            // 点名格式不对当没问过（下次联网再问）。
            final targets = switch (json['targets']) {
              final Object targets => _tryTargets(targets),
              null => null,
            };
            return FileRolloutMemory._(file, installId, decodeRolloutConfig(config), fetchedAt, etag, subject, level, joined.cast<String>(), targets, targets == null ? null : _etagOf(json['targetsEtag']));
          }
          return FileRolloutMemory._(file, installId, decodeRolloutConfig(config), fetchedAt, etag);
        }
      }
    } catch (error, stack) {
      campusLog('[Rollouts] action=memory_read errorType=${error.runtimeType}\n$stack');
    }
    final memory = FileRolloutMemory._(file, base64UrlNoPad(secureRandomBytes(16)), RolloutConfig.empty, null, null);
    await memory._write();
    return memory;
  }

  // 测试用：只在内存里。
  FileRolloutMemory.memory({String installId = 'AAAAAAAAAAAAAAAAAAAAAA', RolloutConfig config = RolloutConfig.empty, DateTime? fetchedAt}) : this._(null, installId, config, fetchedAt, null);

  @override
  RolloutConfig get config => _config;

  @override
  DateTime? get fetchedAt => _fetchedAt;

  @override
  String? get etag => _etag;

  @override
  Future<void> save(RolloutConfig config, DateTime fetchedAt, {String? etag}) {
    _config = config;
    _fetchedAt = fetchedAt.toUtc();
    _etag = etag;
    return _write();
  }

  @override
  int levelOf(String subject) => subject == _subject ? _level : 0;

  @override
  bool joined(String subject, String id) => subject == _subject && _joined.contains(id);

  @override
  List<RolloutTarget> targetsOf(String subject) => subject == _subject ? List.unmodifiable(_targets) : const [];

  @override
  DateTime? accountCreatedOf(String subject) => subject == _subject ? _accountCreatedAt : null;

  @override
  String? targetsEtagOf(String subject) => subject == _subject ? _targetsEtag : null;

  @override
  Future<void> saveTargets(String subject, RolloutTargets targets, {String? etag}) {
    _switchTo(subject);
    _targets
      ..clear()
      ..addAll(targets.flags.take(rolloutTargetLimit));
    _accountCreatedAt = targets.accountCreatedAt;
    _targetsEtag = etag;
    return _write();
  }

  // 换了主体：等级、批次与点名都从头记。
  void _switchTo(String subject) {
    if (subject == _subject) return;
    _subject = subject;
    _level = 0;
    _joined.clear();
    _targets.clear();
    _accountCreatedAt = null;
    _targetsEtag = null;
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
      'etag': ?_etag,
      if (_subject case final subject?) ...{
        'subject': subject,
        'level': _level,
        'joined': [..._joined],
        if (_accountCreatedAt case final created?)
          'targets': {'flags': [for (final target in _targets) {'id': target.id, 'until': target.until?.toUtc().toIso8601String()}], 'accountCreatedAt': created.toIso8601String()},
        'targetsEtag': ?_targetsEtag,
      },
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

RolloutTargets? _tryTargets(Object targets) {
  try {
    return decodeRolloutTargets(targets);
  } on FormatException catch (error, stack) {
    campusLog('[Rollouts] action=memory_targets errorType=${error.runtimeType}\n$stack');
    return null;
  }
}

// 版本号是外部来的短串：只认 1–64 个字母数字与 _ -，别的当没记过（下次取全量）。
String? _etagOf(Object? raw) => raw is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(raw) ? raw : null;
