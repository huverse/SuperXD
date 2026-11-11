import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// 诊断包信封（人工决策见 domain/diagnostic_upload.dart）：只有开发者解得开。一次性 X25519 密钥与开发者公钥协商，HKDF-SHA256 派生 AES-256-GCM 密钥，
// 附加数据绑定版本与一次性公钥；构造同私信信封（social/social_crypto.dart），只是不签名、不压缩（日志包本身是 zip）。
// 布局：版本(1) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16)。不依赖 Flutter：tool/open_diagnostic.dart 用 dart run 直接解。

// 开发者的诊断公钥（X25519，base64url 无填充）。私钥只在开发者本机，换钥用 tool/open_diagnostic.dart --generate，之前上传的包仍要用旧私钥解。
const diagnosticRecipientKey = 'pQ-yDC2n7EHfUNgcuL6eUGNmfssRnOHb6suqpN0pjF0';

const diagnosticSealVersion = 1;
const diagnosticSealOverhead = 1 + 32 + 12 + 16;

final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

Uint8List decodeDiagnosticKey(String text) {
  final bytes = base64Url.decode(base64Url.normalize(text));
  if (bytes.length != 32) throw const FormatException('X25519 密钥应为 32 字节');
  return bytes;
}

String encodeDiagnosticKey(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

// 加密给开发者。日志包最大二十来兆：输出直接拼进一块 Uint8List，不经 List<int> 展开（逐个装箱的整数会慢几十倍、占几倍内存）。
Future<Uint8List> sealDiagnostic(List<int> plain, List<int> recipientPublicKey) async {
  final ephemeral = await _x25519.newKeyPair();
  final ephemeralPublic = (await ephemeral.extractPublicKey()).bytes;
  final shared = await _x25519.sharedSecretKey(keyPair: ephemeral, remotePublicKey: SimplePublicKey(recipientPublicKey, type: KeyPairType.x25519));
  final box = await _aes.encrypt(plain, secretKey: await _sealKey(shared, ephemeralPublic, recipientPublicKey), nonce: _aes.newNonce(), aad: _aad(ephemeralPublic));
  final end = 45 + box.cipherText.length;
  return Uint8List(end + 16)
    ..[0] = diagnosticSealVersion
    ..setRange(1, 33, ephemeralPublic)
    ..setRange(33, 45, box.nonce)
    ..setRange(45, end, box.cipherText)
    ..setRange(end, end + 16, box.mac.bytes);
}

// 开发者用私钥解开（tool/open_diagnostic.dart 与测试用）；版本不对、私钥不对或内容被改过都抛 FormatException。
Future<Uint8List> openDiagnostic(Uint8List sealed, List<int> recipientSeed) async {
  if (sealed.length < diagnosticSealOverhead || sealed[0] != diagnosticSealVersion) throw const FormatException('不是诊断包');
  final ephemeralPublic = Uint8List.sublistView(sealed, 1, 33);
  final keyPair = await _x25519.newKeyPairFromSeed(recipientSeed);
  final shared = await _x25519.sharedSecretKey(keyPair: keyPair, remotePublicKey: SimplePublicKey(ephemeralPublic, type: KeyPairType.x25519));
  final box = SecretBox(Uint8List.sublistView(sealed, 45, sealed.length - 16), nonce: Uint8List.sublistView(sealed, 33, 45), mac: Mac(Uint8List.sublistView(sealed, sealed.length - 16)));
  try {
    final plain = await _aes.decrypt(box, secretKey: await _sealKey(shared, ephemeralPublic, (await keyPair.extractPublicKey()).bytes), aad: _aad(ephemeralPublic));
    return plain is Uint8List ? plain : Uint8List.fromList(plain);
  } on SecretBoxAuthenticationError {
    throw const FormatException('解不开：私钥不对或文件损坏');
  }
}

List<int> _aad(List<int> ephemeralPublic) => [diagnosticSealVersion, ...ephemeralPublic];

Future<SecretKey> _sealKey(SecretKey shared, List<int> ephemeralPublic, List<int> recipientPublic) =>
    _hkdf.deriveKey(secretKey: shared, nonce: [...ephemeralPublic, ...recipientPublic], info: utf8.encode('SXD1-diagnostic'));
