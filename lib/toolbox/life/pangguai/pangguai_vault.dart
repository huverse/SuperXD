import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';

// 胖乖账号的手机号与登录凭据（token，等同登录态，胖乖不给过期时间）只进系统安全存储（命名空间 superxd_pangguai，排除出云备份与设备迁移），
// 业务数据与日志都不存；另记当前用的是哪个账号。
class PangguaiVaultState {
  const PangguaiVaultState({required this.accounts, required this.active});
  final List<PangguaiCredential> accounts;
  final String? active;

  PangguaiCredential? get current => accounts.where((account) => account.phone == active).firstOrNull ?? accounts.firstOrNull;
}

abstract interface class PangguaiVault {
  Future<PangguaiVaultState> load();
  Future<void> save(PangguaiVaultState state);
  // 清除本工具的全部凭据（清除数据时用）。
  Future<void> deleteAll();
}

// 一台手机上最多记这么多个胖乖账号（多账号切换，超出时挤掉最早加的）。
const pangguaiAccountLimit = 10;

String encodePangguaiVault(PangguaiVaultState state) => jsonEncode({
  'active': state.active,
  'accounts': [for (final account in state.accounts) {'phone': account.phone, 'token': account.token}],
});

// 按外部输入读：坏了的整份当没有（记日志），坏的那一项跳过。
PangguaiVaultState decodePangguaiVault(String? raw) {
  const fresh = PangguaiVaultState(accounts: [], active: null);
  if (raw == null || raw.isEmpty) return fresh;
  try {
    final json = jsonDecode(raw);
    if (json is! Map) return fresh;
    final accounts = [
      for (final item in json['accounts'] is List ? json['accounts'] as List : const [])
        if (item is Map && item['phone'] is String && item['token'] is String) PangguaiCredential(phone: item['phone'] as String, token: item['token'] as String),
    ];
    return PangguaiVaultState(accounts: accounts.take(pangguaiAccountLimit).toList(), active: json['active'] is String ? json['active'] as String : null);
  } on FormatException catch (error, stack) {
    campusLog('[Pangguai] action=read_vault errorType=${error.runtimeType}\n$stack');
    return fresh;
  }
}

class SecurePangguaiVault implements PangguaiVault {
  SecurePangguaiVault()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(storageNamespace: 'superxd_pangguai', resetOnError: false),
        iOptions: IOSOptions(accountName: 'superxd_pangguai', accessibility: KeychainAccessibility.first_unlock_this_device),
      );
  final FlutterSecureStorage _storage;
  static const _key = 'state';

  @override
  Future<PangguaiVaultState> load() async => decodePangguaiVault(await _storage.read(key: _key));

  @override
  Future<void> save(PangguaiVaultState state) => _storage.write(key: _key, value: encodePangguaiVault(state));

  // 只删 superxd_pangguai 命名空间里的项，不碰教务凭据、私信身份与别的工具。
  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

class MemoryPangguaiVault implements PangguaiVault {
  String? raw;
  @override
  Future<PangguaiVaultState> load() async => decodePangguaiVault(raw);
  @override
  Future<void> save(PangguaiVaultState state) async => raw = encodePangguaiVault(state);
  @override
  Future<void> deleteAll() async => raw = null;
}
