import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:superxd/social/social_crypto.dart';

// 设备身份私钥种子的存放处。
abstract interface class IdentityVault {
  Future<SocialIdentity?> read();
  Future<void> write(SocialIdentity identity);
  Future<void> delete();
}

// 系统安全存储（Android Keystore 加密）。命名空间已排除出云备份与设备迁移（backup_rules.xml），身份不随备份搬到别的设备。
class SecureIdentityVault implements IdentityVault {
  SecureIdentityVault() : _storage = const FlutterSecureStorage(aOptions: AndroidOptions(storageNamespace: 'superxd_social', resetOnError: false));
  final FlutterSecureStorage _storage;
  static const _key = 'identity';

  @override
  Future<SocialIdentity?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map || data['version'] != 1 || data['sign'] is! String || data['box'] is! String) throw const FormatException('保存的私信身份不可用');
    return SocialIdentity.fromSeeds(decodeBase64UrlNoPad(data['sign'] as String, length: 32), decodeBase64UrlNoPad(data['box'] as String, length: 32));
  }

  @override
  Future<void> write(SocialIdentity identity) => _storage.write(key: _key, value: jsonEncode({'version': 1, 'sign': base64UrlNoPad(identity.signSeed), 'box': base64UrlNoPad(identity.boxSeed)}));

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

class MemoryIdentityVault implements IdentityVault {
  SocialIdentity? identity;
  @override
  Future<SocialIdentity?> read() async => identity;
  @override
  Future<void> write(SocialIdentity value) async => identity = value;
  @override
  Future<void> delete() async => identity = null;
}
