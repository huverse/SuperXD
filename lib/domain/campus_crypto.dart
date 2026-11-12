import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// 各模块共用的密码学小工具，只在这里实现一遍：base64url 无填充的编解码、密码学安全的随机字节、Ed25519 验签。
// 以前私信、签名信封、诊断包、学习通代签包与发版工具各写一份，解码的宽严不一（有的认填充与非规范写法）。
// 各协议自己的布局、域前缀与加密构造（私信信封、诊断包信封、代签凭据包）仍留在各自文件。纯 Dart，tool 下的命令行工具也直接用。

final _random = Random.secure();
final _ed25519 = Ed25519();

String base64UrlNoPad(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

// 严格解码外部给的 base64url：只认无填充的规范写法（编回去要一字不差），给了 length 还要正好这么多字节；不合格返回 null。
Uint8List? tryDecodeBase64UrlNoPad(String text, {int? length}) {
  if (!RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(text) || text.length % 4 == 1) return null;
  final Uint8List bytes;
  try {
    // 末位的低位不为 0（非规范写法）时 dart:convert 直接抛。
    bytes = base64Url.decode(text.padRight((text.length + 3) ~/ 4 * 4, '='));
  } on FormatException {
    return null;
  }
  if (base64UrlNoPad(bytes) != text || length != null && bytes.length != length) return null;
  return bytes;
}

Uint8List secureRandomBytes(int length) => Uint8List.fromList([for (var index = 0; index < length; index++) _random.nextInt(256)]);

// 公钥 32 字节、签名 64 字节，长度不对直接算验不过。
Future<bool> verifyEd25519(List<int> publicKey, List<int> message, List<int> signature) async {
  if (publicKey.length != 32 || signature.length != 64) return false;
  return _ed25519.verify(message, signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
}
