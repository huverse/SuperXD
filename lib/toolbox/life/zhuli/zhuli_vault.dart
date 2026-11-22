import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';

// 住理账号的手机号与登录密码只进系统安全存储（命名空间 superxd_zhuli，排除出云备份与设备迁移），业务库与日志都不存；
// 密码要留着：住理的会话 20–40 分钟就过期，洗澡中途过期时要在后台重登才能关水（人工决策见 zhuli_service.dart 文件头）。
// 另存当前用的是哪个账号，与本工具在这台手机上的随机设备串（登录时报给住理的 deviceToken，不是硬件标识）。
class ZhuliVaultState {
  const ZhuliVaultState({required this.accounts, required this.active, required this.device});
  final List<ZhuliCredential> accounts;
  final String? active;
  final String device;

  ZhuliCredential? get current => accounts.where((account) => account.phone == active).firstOrNull ?? accounts.firstOrNull;
}

abstract interface class ZhuliVault {
  Future<ZhuliVaultState> load();
  Future<void> save(ZhuliVaultState state);
  // 清除本工具的全部凭据（清除数据时用）。
  Future<void> deleteAll();
}

// 一台手机上最多记这么多个住理账号（多账号切换，超出时挤掉最早加的）。
const zhuliAccountLimit = 10;

String encodeZhuliVault(ZhuliVaultState state) => jsonEncode({
  'device': state.device,
  'active': state.active,
  'accounts': [for (final account in state.accounts) {'phone': account.phone, 'password': account.password}],
});

// 按外部输入读：坏了的整份当没有（记日志），坏的那一项跳过。
ZhuliVaultState decodeZhuliVault(String? raw) {
  final fresh = ZhuliVaultState(accounts: const [], active: null, device: base64UrlNoPad(secureRandomBytes(16)));
  if (raw == null || raw.isEmpty) return fresh;
  try {
    final json = jsonDecode(raw);
    if (json is! Map || json['device'] is! String) return fresh;
    final accounts = [
      for (final item in json['accounts'] is List ? json['accounts'] as List : const [])
        if (item is Map && item['phone'] is String && item['password'] is String) ZhuliCredential(phone: item['phone'] as String, password: item['password'] as String),
    ];
    return ZhuliVaultState(accounts: accounts.take(zhuliAccountLimit).toList(), active: json['active'] is String ? json['active'] as String : null, device: json['device'] as String);
  } on FormatException catch (error, stack) {
    campusLog('[Zhuli] action=read_vault errorType=${error.runtimeType}\n$stack');
    return fresh;
  }
}

class SecureZhuliVault implements ZhuliVault {
  SecureZhuliVault()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(storageNamespace: 'superxd_zhuli', resetOnError: false),
        iOptions: IOSOptions(accountName: 'superxd_zhuli', accessibility: KeychainAccessibility.first_unlock_this_device),
      );
  final FlutterSecureStorage _storage;
  static const _key = 'state';

  @override
  Future<ZhuliVaultState> load() async {
    final state = decodeZhuliVault(await _storage.read(key: _key));
    return state;
  }

  @override
  Future<void> save(ZhuliVaultState state) => _storage.write(key: _key, value: encodeZhuliVault(state));

  // 只删 superxd_zhuli 命名空间里的项，不碰教务凭据、私信身份与别的工具。
  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

class MemoryZhuliVault implements ZhuliVault {
  String? raw;
  @override
  Future<ZhuliVaultState> load() async => decodeZhuliVault(raw);
  @override
  Future<void> save(ZhuliVaultState state) async => raw = encodeZhuliVault(state);
  @override
  Future<void> deleteAll() async => raw = null;
}
