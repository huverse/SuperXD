import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class RememberedCredential {
  const RememberedCredential({required this.account, required this.password});
  final String account;
  final String password;
}

abstract interface class CredentialStore {
  Future<RememberedCredential?> read(String accountKey);
  Future<void> write(String accountKey, RememberedCredential credential);
  Future<void> delete(String accountKey);
}

// [人工决策-2026-09-24 23:39:30] 仅明确同意记住且认证成功后加密保存鉴权数据；未开启不保存，关闭或主动退出即删除。
// 系统安全存储管理密钥与密文；业务SQLite、日志和账号索引不存登录密码。
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore() : _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(storageNamespace: 'superxd_credentials', resetOnError: false),
  );
  final FlutterSecureStorage _storage;
  String _key(String accountKey) => 'remembered_$accountKey';
  @override
  Future<RememberedCredential?> read(String accountKey) async {
    final raw = await _storage.read(key: _key(accountKey));
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map || data['account'] is! String || data['password'] is! String || data['version'] != 1) {
      throw const FormatException('保存的鉴权数据不可用');
    }
    return RememberedCredential(account: data['account'] as String, password: data['password'] as String);
  }
  @override
  Future<void> write(String accountKey, RememberedCredential credential) => _storage.write(key: _key(accountKey), value: jsonEncode({'version': 1, 'account': credential.account, 'password': credential.password}));
  @override
  Future<void> delete(String accountKey) => _storage.delete(key: _key(accountKey));
}
