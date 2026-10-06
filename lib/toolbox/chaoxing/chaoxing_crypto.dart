import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

// 学习通固定的传输加密：手机号与密码用 AES-128-CBC（PKCS7，IV 与密钥同为固定串）后 Base64。
// 这是对方的协议事实，不是我们的安全设计，凭据本身另存系统安全存储。
const chaoxingTransferKey = 'u2oh6Vu^HWe4_AES';

final _aesCbc128 = AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty);

Future<String> chaoxingEncrypt(String plain) async {
  final key = utf8.encode(chaoxingTransferKey);
  final box = await _aesCbc128.encrypt(utf8.encode(plain), secretKey: SecretKey(key), nonce: key);
  return base64.encode(box.cipherText);
}

String chaoxingMd5(String value) => hash.md5.convert(utf8.encode(value)).toString();

List<int> chaoxingSha256Bytes(List<int> value) => hash.sha256.convert(value).bytes;
