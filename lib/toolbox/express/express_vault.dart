import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 拼多多登录会话（AccessToken 与账号 Cookie）：等同账号登录态，只进系统安全存储，业务库与日志都不存。
abstract interface class ExpressVault {
  Future<PddSession?> load();
  Future<void> save(PddSession session);

  // 已绑号的驿站包裹是否已关联进本账号（见 ExpressController.queryStationPackages）；随会话一起清，重新登录后再补一次。
  Future<bool> stationLinked();
  Future<void> saveStationLinked(bool linked);

  // 每件待取件寄到的手机尾号（键见 ExpressController._ownerKey）：查到一次就存，只留当前还在待取的件（见 _fillOwners），随会话一起清。
  Future<Map<String, String>> ownerTails();
  Future<void> saveOwnerTails(Map<String, String> tails);

  // 清除本工具的全部凭据（退出登录与清除数据时用）。
  Future<void> deleteAll();
}

class SecureExpressVault implements ExpressVault {
  SecureExpressVault()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(storageNamespace: 'superxd_pdd', resetOnError: false),
        iOptions: IOSOptions(accountName: 'superxd_pdd', accessibility: KeychainAccessibility.first_unlock_this_device),
      );
  final FlutterSecureStorage _storage;

  static const _sessionKey = 'session';
  static const _stationLinkedKey = 'station_linked';
  static const _ownerTailsKey = 'owner_tails';

  // 会话按外部输入读：坏了当没登录（记日志），不让整个工具打不开。
  @override
  Future<PddSession?> load() async {
    final raw = await _storage.read(key: _sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final session = PddSession.decode(raw);
      return session.isValid ? session : null;
    } on FormatException catch (error, stack) {
      campusLog('[Express] action=read_session errorType=${error.runtimeType}\n$stack');
      return null;
    }
  }

  @override
  Future<void> save(PddSession session) => _storage.write(key: _sessionKey, value: session.encode());

  @override
  Future<bool> stationLinked() async => await _storage.read(key: _stationLinkedKey) == 'true';

  @override
  Future<void> saveStationLinked(bool linked) => _storage.write(key: _stationLinkedKey, value: '$linked');

  // 按外部输入读：坏了或不是字符串的项当没有（下次查驿站再补查）。
  @override
  Future<Map<String, String>> ownerTails() async {
    final raw = await _storage.read(key: _ownerTailsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? {for (final entry in decoded.entries) if (entry.value is String) '${entry.key}': entry.value as String} : {};
    } on FormatException catch (error, stack) {
      campusLog('[Express] action=read_owner_tails errorType=${error.runtimeType}\n$stack');
      return {};
    }
  }

  @override
  Future<void> saveOwnerTails(Map<String, String> tails) => _storage.write(key: _ownerTailsKey, value: jsonEncode(tails));

  // 只删 superxd_pdd 命名空间里的项（插件按命名空间隔离），不碰教务凭据、私信身份与学习通。
  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

class MemoryExpressVault implements ExpressVault {
  PddSession? _session;
  bool _stationLinked = false;
  Map<String, String> _ownerTails = {};

  @override
  Future<PddSession?> load() async => _session;

  @override
  Future<void> save(PddSession session) async => _session = session;

  @override
  Future<bool> stationLinked() async => _stationLinked;

  @override
  Future<void> saveStationLinked(bool linked) async => _stationLinked = linked;

  @override
  Future<Map<String, String>> ownerTails() async => {..._ownerTails};

  @override
  Future<void> saveOwnerTails(Map<String, String> tails) async => _ownerTails = {...tails};

  @override
  Future<void> deleteAll() async {
    _session = null;
    _stationLinked = false;
    _ownerTails = {};
  }
}
