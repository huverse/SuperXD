import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// 学习通账号的密文密码与 Cookie：只进系统安全存储，业务库只存账号索引。
abstract interface class ChaoxingVault {
  Future<String?> readPassword(String phoneNumber);
  Future<void> writePassword(String phoneNumber, String encryptedPassword);
  Future<Map<String, String>?> readCookies(String phoneNumber);
  Future<void> writeCookies(String phoneNumber, Map<String, String> cookies);
  Future<void> delete(String phoneNumber);
}

class SecureChaoxingVault implements ChaoxingVault {
  SecureChaoxingVault()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(storageNamespace: 'superxd_chaoxing', resetOnError: false),
      );
  final FlutterSecureStorage _storage;

  static String _passwordKey(String phoneNumber) => 'password_$phoneNumber';
  static String _cookieKey(String phoneNumber) => 'cookies_$phoneNumber';

  @override
  Future<String?> readPassword(String phoneNumber) => _storage.read(key: _passwordKey(phoneNumber));

  @override
  Future<void> writePassword(String phoneNumber, String encryptedPassword) =>
      _storage.write(key: _passwordKey(phoneNumber), value: encryptedPassword);

  @override
  Future<Map<String, String>?> readCookies(String phoneNumber) async {
    final raw = await _storage.read(key: _cookieKey(phoneNumber));
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map) throw const FormatException('保存的学习通会话不可用');
    return data.map((key, value) => MapEntry('$key', '$value'));
  }

  @override
  Future<void> writeCookies(String phoneNumber, Map<String, String> cookies) =>
      _storage.write(key: _cookieKey(phoneNumber), value: jsonEncode(cookies));

  @override
  Future<void> delete(String phoneNumber) async {
    await _storage.delete(key: _passwordKey(phoneNumber));
    await _storage.delete(key: _cookieKey(phoneNumber));
  }
}

class MemoryChaoxingVault implements ChaoxingVault {
  final passwords = <String, String>{};
  final cookies = <String, Map<String, String>>{};

  @override
  Future<String?> readPassword(String phoneNumber) async => passwords[phoneNumber];

  @override
  Future<void> writePassword(String phoneNumber, String encryptedPassword) async {
    passwords[phoneNumber] = encryptedPassword;
  }

  @override
  Future<Map<String, String>?> readCookies(String phoneNumber) async => cookies[phoneNumber];

  @override
  Future<void> writeCookies(String phoneNumber, Map<String, String> value) async {
    cookies[phoneNumber] = Map.of(value);
  }

  @override
  Future<void> delete(String phoneNumber) async {
    passwords.remove(phoneNumber);
    cookies.remove(phoneNumber);
  }
}
