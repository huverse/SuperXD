import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:superxd/domain/app_account.dart';

// 应用账号登录时封装口令摘要的信封（人工决策见 domain/app_account.dart）：只有中转打得开，而且只认发起的这台设备。
// 一次性 X25519 与中转公钥协商，HKDF-SHA256（盐 = 一次性公钥 + 中转公钥，info = SXD1-account-sign-in）派生 AES-256-GCM 密钥，
// 附加数据绑定版本、一次性公钥与设备号。布局：版本(1) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16)。
// 服务端 server/src/modules/account/account_keys.ts 与此一致，共用 server/test/vectors/account_seal_v1.json。

// 中转的账号公钥（X25519，base64url 无填充）。私钥只在服务器 .env 的 RELAY_ACCOUNT_SEAL_KEY 与开发者本机备份里；换钥两边一起换，旧客户端随之登录不了。
const accountSealKey = 'QdMCdzAMoSJHcgbDWimiSHt1xFIPIUEy13k_sH2FhVw';

const accountSealVersion = 1;

final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

Future<Uint8List> sealAccountProof(KingoSignInProof proof, String deviceId, List<int> recipientPublicKey, {SimpleKeyPair? ephemeral, List<int>? nonce}) async {
  final keyPair = ephemeral ?? await _x25519.newKeyPair();
  final ephemeralPublic = (await keyPair.extractPublicKey()).bytes;
  final shared = await _x25519.sharedSecretKey(keyPair: keyPair, remotePublicKey: SimplePublicKey(recipientPublicKey, type: KeyPairType.x25519));
  final key = await _hkdf.deriveKey(secretKey: shared, nonce: [...ephemeralPublic, ...recipientPublicKey], info: utf8.encode('SXD1-account-sign-in'));
  final box = await _aes.encrypt(utf8.encode(jsonEncode(proof.toJson())), secretKey: key, nonce: nonce ?? _aes.newNonce(), aad: [accountSealVersion, ...ephemeralPublic, ...utf8.encode(deviceId)]);
  return Uint8List.fromList([accountSealVersion, ...ephemeralPublic, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}
