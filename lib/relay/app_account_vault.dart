import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/relay/relay_crypto.dart';

// 应用账号设备密钥的系统安全存储：单独的命名空间，与私信身份互不关联；同样排除出安卓云备份与设备迁移
// （backup_rules.xml、data_extraction_rules.xml），iOS 上仅本机级别、新装后第一次启动清掉（ios/Runner/DeviceOnlyData.swift）。
const appAccountStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(storageNamespace: 'superxd_account', resetOnError: false),
  iOptions: IOSOptions(accountName: 'superxd_account', accessibility: KeychainAccessibility.first_unlock_this_device),
);

// 一个应用账号在本机的记录：设备密钥（同私信身份的格式）、账号号与用户名（11-15 以前的旧记录没有用户名，为空）。
class AppAccountKey {
  const AppAccountKey({required this.identity, required this.accountId, this.username = ''});
  final RelayIdentity identity;
  final String accountId;
  final String username;
}

abstract interface class AppAccountVault {
  Future<AppAccountKey?> read(String slot);
  Future<void> write(String slot, AppAccountKey key);
  Future<void> delete(String slot);
  // 存着的全部键（清理 11-15 以前每个教务账号一把的旧密钥时用）。
  Future<List<String>> slots();
}

class SecureAppAccountVault implements AppAccountVault {
  const SecureAppAccountVault([this._storage = appAccountStorage]);
  final FlutterSecureStorage _storage;

  @override
  Future<AppAccountKey?> read(String slot) async {
    final raw = await _storage.read(key: slot);
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map || data['version'] != 1 || data['sign'] is! String || data['box'] is! String || data['accountId'] is! String || (data['username'] ?? '') is! String) {
      throw const FormatException('保存的应用账号不可用');
    }
    return AppAccountKey(
      identity: await RelayIdentity.fromSeeds(decodeBase64UrlNoPad(data['sign'] as String, length: 32), decodeBase64UrlNoPad(data['box'] as String, length: 32)),
      accountId: data['accountId'] as String,
      username: (data['username'] ?? '') as String,
    );
  }

  @override
  Future<void> write(String slot, AppAccountKey key) => _storage.write(
    key: slot,
    value: jsonEncode({'version': 1, 'sign': base64UrlNoPad(key.identity.signSeed), 'box': base64UrlNoPad(key.identity.boxSeed), 'accountId': key.accountId, 'username': key.username}),
  );

  @override
  Future<void> delete(String slot) => _storage.delete(key: slot);

  @override
  Future<List<String>> slots() async => (await _storage.readAll()).keys.toList();
}

class MemoryAppAccountVault implements AppAccountVault {
  final records = <String, AppAccountKey>{};
  @override
  Future<AppAccountKey?> read(String slot) async => records[slot];
  @override
  Future<void> write(String slot, AppAccountKey key) async => records[slot] = key;
  @override
  Future<void> delete(String slot) async => records.remove(slot);
  @override
  Future<List<String>> slots() async => records.keys.toList();
}

// 安全存储里这台设备应用账号的键（11-15 起一台设备一个，与教务各管各的）。11-15 以前每个教务账号一把，键是 account.<教务身份的哈希>（清理见 relay_app_account.dart 的 dropLegacy）。
const appAccountSlot = 'app_account';
