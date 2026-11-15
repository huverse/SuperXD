import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// 应用账号的密码与恢复码在发出前封装的信封（人工决策见 domain/app_account.dart）：中转是明文 HTTP，不封装就会被同一网络里的人看到。
// 只有中转打得开，而且只认发起的这台设备（同一设备重放整条请求由请求签名的随机数挡住）。
// 一次性 X25519 与中转公钥协商，HKDF-SHA256（盐 = 一次性公钥 + 中转公钥，info = SXD1-account-sign-in）派生 AES-256-GCM 密钥，
// 附加数据绑定版本、一次性公钥与设备号。布局：版本(1) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16)。明文是 UTF-8 的 JSON 对象。
// 服务端 server/src/modules/account/account_keys.ts 与此一致，共用 server/test/vectors/account_seal_v1.json。

// 中转的账号公钥（X25519，base64url 无填充）。私钥只在服务器 .env 的 RELAY_ACCOUNT_SEAL_KEY 与开发者本机备份里；换钥两边一起换，旧客户端随之登录不了。
const accountSealKey = 'QdMCdzAMoSJHcgbDWimiSHt1xFIPIUEy13k_sH2FhVw';

const accountSealVersion = 1;

final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

Future<Uint8List> sealAccountSecrets(Map<String, Object?> secrets, String deviceId, List<int> recipientPublicKey, {SimpleKeyPair? ephemeral, List<int>? nonce}) async {
  final keyPair = ephemeral ?? await _x25519.newKeyPair();
  final ephemeralPublic = (await keyPair.extractPublicKey()).bytes;
  final shared = await _x25519.sharedSecretKey(keyPair: keyPair, remotePublicKey: SimplePublicKey(recipientPublicKey, type: KeyPairType.x25519));
  final key = await _hkdf.deriveKey(secretKey: shared, nonce: [...ephemeralPublic, ...recipientPublicKey], info: utf8.encode('SXD1-account-sign-in'));
  final box = await _aes.encrypt(utf8.encode(jsonEncode(secrets)), secretKey: key, nonce: nonce ?? _aes.newNonce(), aad: [accountSealVersion, ...ephemeralPublic, ...utf8.encode(deviceId)]);
  return Uint8List.fromList([accountSealVersion, ...ephemeralPublic, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}
