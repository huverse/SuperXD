import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

// 应用账号的密码与恢复码在发出前封装的信封（人工决策见 domain/app_account.dart）：当初中转是明文 HTTP，不封装就会被同一网络里的人看到；11-18 起走 HTTPS 后照旧封装（中转的接入层与日志也碰不到明文）。
// 只有中转打得开，而且只认发起的这台设备（同一设备重放整条请求由请求签名的随机数挡住）。
// 一次性 X25519 与中转公钥协商，HKDF-SHA256（盐 = 一次性公钥 + 中转公钥，info = SXD1-account-sign-in）派生 AES-256-GCM 密钥，
// 附加数据绑定版本、钥号、一次性公钥与设备号。布局（第 2 版）：版本(1) | 钥号(8) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16)。明文是 UTF-8 的 JSON 对象。
// 钥号是中转公钥 sha256 的前 8 字节（accountSealKeyId），服务器按它挑私钥、可以同时认几把，换钥不断旧客户端（11-17 起；第 1 版没有钥号，服务器照旧认）。
// 服务端 server/src/modules/account/account_keys.ts 与此一致，共用 server/test/vectors/account_seal_v2.json。

// 中转的账号公钥（X25519，base64url 无填充），封装只用这一把。私钥只在服务器 .env 的 RELAY_ACCOUNT_SEAL_KEY 与开发者本机备份里。
// 换钥：先把新私钥加进服务器（新旧都认），再发把这里换成新公钥的版本，等旧版本都低于最低可用版本再从服务器删掉旧钥（步骤见 server/README.md「部署」应用账号一条）。
// 这里只放一把：封装这一侧用不上备选的钥，要备选就得在服务器不认时自动换一把重发，项目不自动重试。
const accountSealKey = 'QdMCdzAMoSJHcgbDWimiSHt1xFIPIUEy13k_sH2FhVw';

const accountSealVersion = 2;

final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

List<int> accountSealKeyId(List<int> publicKey) => hash.sha256.convert(publicKey).bytes.sublist(0, 8);

Future<Uint8List> sealAccountSecrets(Map<String, Object?> secrets, String deviceId, List<int> recipientPublicKey, {SimpleKeyPair? ephemeral, List<int>? nonce}) async {
  final keyPair = ephemeral ?? await _x25519.newKeyPair();
  final ephemeralPublic = (await keyPair.extractPublicKey()).bytes;
  final keyId = accountSealKeyId(recipientPublicKey);
  final shared = await _x25519.sharedSecretKey(keyPair: keyPair, remotePublicKey: SimplePublicKey(recipientPublicKey, type: KeyPairType.x25519));
  final key = await _hkdf.deriveKey(secretKey: shared, nonce: [...ephemeralPublic, ...recipientPublicKey], info: utf8.encode('SXD1-account-sign-in'));
  final box = await _aes.encrypt(utf8.encode(jsonEncode(secrets)), secretKey: key, nonce: nonce ?? _aes.newNonce(), aad: [accountSealVersion, ...keyId, ...ephemeralPublic, ...utf8.encode(deviceId)]);
  return Uint8List.fromList([accountSealVersion, ...keyId, ...ephemeralPublic, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}
