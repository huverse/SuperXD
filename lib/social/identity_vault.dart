import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/social/social_crypto.dart';

// 私信身份私钥种子的存放处：每个应用账号一项（键由 social_spaces.dart 定），另记旧版留下的设备级私信归哪个应用账号。
abstract interface class IdentityVault {
  Future<SocialIdentity?> read(String key);
  Future<void> write(String key, SocialIdentity identity);
  Future<void> delete(String key);
  // 旧版留下的设备级私信归哪个应用账号（social_spaces.dart），还没定为空。
  Future<String?> legacyOwner();
  Future<void> setLegacyOwner(String accountId);
}

// 系统安全存储（Android Keystore 加密），私信身份的命名空间 superxd_social，已排除出云备份与设备迁移（backup_rules.xml），身份不随备份搬到别的设备。
class SecureIdentityVault implements IdentityVault {
  const SecureIdentityVault();
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions(storageNamespace: 'superxd_social', resetOnError: false), iOptions: IOSOptions(accountName: 'superxd_social', accessibility: KeychainAccessibility.first_unlock_this_device));
  static const _legacyOwner = 'legacyOwner';

  @override
  Future<SocialIdentity?> read(String key) async {
    final raw = await _storage.read(key: key);
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map || data['version'] != 1 || data['sign'] is! String || data['box'] is! String) throw const FormatException('保存的设备身份不可用');
    return SocialIdentity.fromSeeds(decodeBase64UrlNoPad(data['sign'] as String, length: 32), decodeBase64UrlNoPad(data['box'] as String, length: 32));
  }

  @override
  Future<void> write(String key, SocialIdentity identity) => _storage.write(key: key, value: jsonEncode({'version': 1, 'sign': base64UrlNoPad(identity.signSeed), 'box': base64UrlNoPad(identity.boxSeed)}));

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<String?> legacyOwner() => _storage.read(key: _legacyOwner);

  @override
  Future<void> setLegacyOwner(String accountId) => _storage.write(key: _legacyOwner, value: accountId);
}

class MemoryIdentityVault implements IdentityVault {
  final identities = <String, SocialIdentity>{};
  String? owner;
  @override
  Future<SocialIdentity?> read(String key) async => identities[key];
  @override
  Future<void> write(String key, SocialIdentity value) async => identities[key] = value;
  @override
  Future<void> delete(String key) async => identities.remove(key);
  @override
  Future<String?> legacyOwner() async => owner;
  @override
  Future<void> setLegacyOwner(String accountId) async => owner = accountId;
}
