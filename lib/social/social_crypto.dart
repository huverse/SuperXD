import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

// 协议 v1 的客户端密码学，与服务端 server/src/common/crypto/relay_crypto.ts 逐字节一致（共用 server/test/vectors/protocol_v1.json）。
// 设备身份：Ed25519 签名密钥 + X25519 加密密钥，私钥种子只在系统安全存储里。
// 消息：发送方用自己的签名私钥签明文，再用一次性 X25519 密钥与收件人加密公钥协商，HKDF-SHA256 派生 AES-256-GCM 密钥加密。
// 中转服务只见密文；收件人验签确认来自好友本人，附加数据绑定收件人设备号，密文不能转投给别人。

final _ed25519 = Ed25519();
final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final _random = Random.secure();

const envelopeVersion = 1;
// 解压后的消息明文上限 1MB，防压缩炸弹。
const plaintextLimit = 1024 * 1024;

class SocialCryptoException implements Exception {
  const SocialCryptoException(this.message);
  final String message;
  @override
  String toString() => message;
}

String base64UrlNoPad(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List decodeBase64UrlNoPad(String text, {int? length}) {
  if (!RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(text)) throw const SocialCryptoException('编码不正确');
  final bytes = base64Url.decode(text.padRight((text.length + 3) ~/ 4 * 4, '='));
  if (base64UrlNoPad(bytes) != text || length != null && bytes.length != length) throw const SocialCryptoException('编码不正确');
  return bytes;
}

Uint8List randomBytes(int length) => Uint8List.fromList([for (var index = 0; index < length; index++) _random.nextInt(256)]);

String deviceIdOf(List<int> signPublicKey) => base64UrlNoPad(hash.sha256.convert(signPublicKey).bytes.sublist(0, 16));

Uint8List requestCanonical(String method, String pathWithQuery, String time, String nonce, List<int> body) =>
    utf8.encode(['SXD1', method.toUpperCase(), pathWithQuery, time, nonce, base64UrlNoPad(hash.sha256.convert(body).bytes)].join('\n'));

Uint8List inviteProofCanonical(String inviteId, String redeemerDeviceId) => utf8.encode(['SXD1-invite', inviteId, redeemerDeviceId].join('\n'));

// 消息签名带域前缀，签名不能被挪作请求或邀请签名使用。
Uint8List _messageCanonical(List<int> compressed) => Uint8List.fromList([...utf8.encode('SXD1-msg\n'), ...compressed]);

Future<Uint8List> signWithSeed(List<int> seed, List<int> message) async {
  final signature = await _ed25519.sign(message, keyPair: await _ed25519.newKeyPairFromSeed(seed));
  return Uint8List.fromList(signature.bytes);
}

Future<bool> verifySignature(List<int> publicKey, List<int> message, List<int> signature) async {
  if (publicKey.length != 32 || signature.length != 64) return false;
  return _ed25519.verify(message, signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
}

Future<Uint8List> ed25519PublicOf(List<int> seed) async {
  final keyPair = await _ed25519.newKeyPairFromSeed(seed);
  return Uint8List.fromList((await keyPair.extractPublicKey()).bytes);
}

Future<Uint8List> x25519PublicOf(List<int> seed) async {
  final keyPair = await _x25519.newKeyPairFromSeed(seed);
  return Uint8List.fromList((await keyPair.extractPublicKey()).bytes);
}

// 本机设备身份：私钥种子只在内存与安全存储里，公钥与设备号随处可给。
class SocialIdentity {
  SocialIdentity._(this.signSeed, this.boxSeed, this.signPublicKey, this.boxPublicKey) : deviceId = deviceIdOf(signPublicKey);
  final Uint8List signSeed;
  final Uint8List boxSeed;
  final Uint8List signPublicKey;
  final Uint8List boxPublicKey;
  final String deviceId;

  static Future<SocialIdentity> fromSeeds(List<int> signSeed, List<int> boxSeed) async {
    if (signSeed.length != 32 || boxSeed.length != 32) throw const SocialCryptoException('身份密钥不完整');
    return SocialIdentity._(Uint8List.fromList(signSeed), Uint8List.fromList(boxSeed), await ed25519PublicOf(signSeed), await x25519PublicOf(boxSeed));
  }

  static Future<SocialIdentity> generate() => fromSeeds(randomBytes(32), randomBytes(32));

  Future<Uint8List> sign(List<int> message) => signWithSeed(signSeed, message);
}

// 对方的公开身份（来自二维码或问候消息），设备号由签名公钥推出，不信任外部给的设备号。
class PeerKeys {
  PeerKeys(this.signPublicKey, this.boxPublicKey) : deviceId = deviceIdOf(signPublicKey) {
    if (signPublicKey.length != 32 || boxPublicKey.length != 32) throw const SocialCryptoException('公钥不完整');
  }
  final Uint8List signPublicKey;
  final Uint8List boxPublicKey;
  final String deviceId;
}

Uint8List _aad(List<int> ephemeral, String recipientDeviceId) => Uint8List.fromList([envelopeVersion, ...ephemeral, ...utf8.encode(recipientDeviceId)]);

// 加密给收件人：明文先 gzip，再由发送方签名，签名与压缩后的明文一起加密。
// 信封布局：版本(1) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16)。
Future<Uint8List> sealEnvelope({required SocialIdentity sender, required PeerKeys recipient, required Map<String, Object?> message}) async {
  final compressed = gzip.encode(utf8.encode(jsonEncode(message)));
  final signature = await sender.sign(_messageCanonical(compressed));
  final ephemeral = await _x25519.newKeyPair();
  final ephemeralPublic = (await ephemeral.extractPublicKey()).bytes;
  final key = await _envelopeKey(await _x25519.sharedSecretKey(keyPair: ephemeral, remotePublicKey: SimplePublicKey(recipient.boxPublicKey, type: KeyPairType.x25519)), ephemeralPublic, recipient.boxPublicKey);
  final nonce = randomBytes(12);
  final box = await _aes.encrypt([...signature, ...compressed], secretKey: key, nonce: nonce, aad: _aad(ephemeralPublic, recipient.deviceId));
  return Uint8List.fromList([envelopeVersion, ...ephemeralPublic, ...nonce, ...box.cipherText, ...box.mac.bytes]);
}

class OpenedEnvelope {
  const OpenedEnvelope(this.message, this.signature, this.signed);
  final Map<String, Object?> message;
  final Uint8List signature;
  // 签名覆盖的原文；发送方公钥确定后用 verifyOpened 验签。
  final Uint8List signed;
}

// 解密自己收到的信封；验签需要发送方公钥，由调用方在确认发送方后进行。
Future<OpenedEnvelope> openEnvelope({required SocialIdentity recipient, required List<int> envelope}) async {
  if (envelope.length < 1 + 32 + 12 + 64 + 16 + 1 || envelope[0] != envelopeVersion) throw const SocialCryptoException('信封格式不正确');
  final ephemeralPublic = envelope.sublist(1, 33), nonce = envelope.sublist(33, 45);
  final cipherText = envelope.sublist(45, envelope.length - 16), mac = envelope.sublist(envelope.length - 16);
  final keyPair = await _x25519.newKeyPairFromSeed(recipient.boxSeed);
  final key = await _envelopeKey(await _x25519.sharedSecretKey(keyPair: keyPair, remotePublicKey: SimplePublicKey(ephemeralPublic, type: KeyPairType.x25519)), ephemeralPublic, recipient.boxPublicKey);
  final List<int> plain;
  try {
    plain = await _aes.decrypt(SecretBox(cipherText, nonce: nonce, mac: Mac(mac)), secretKey: key, aad: _aad(ephemeralPublic, recipient.deviceId));
  } on SecretBoxAuthenticationError {
    throw const SocialCryptoException('信封无法解密');
  }
  final signature = Uint8List.fromList(plain.sublist(0, 64)), compressed = plain.sublist(64);
  final decoded = <int>[];
  await for (final chunk in Stream.value(compressed).transform(gzip.decoder)) {
    decoded.addAll(chunk);
    if (decoded.length > plaintextLimit) throw const SocialCryptoException('消息过大');
  }
  final message = jsonDecode(utf8.decode(decoded));
  if (message is! Map) throw const SocialCryptoException('消息格式不正确');
  return OpenedEnvelope(message.cast<String, Object?>(), signature, _messageCanonical(compressed));
}

Future<bool> verifyOpened(OpenedEnvelope opened, List<int> senderSignPublicKey) => verifySignature(senderSignPublicKey, opened.signed, opened.signature);

Future<SecretKey> _envelopeKey(SecretKey shared, List<int> ephemeralPublic, List<int> recipientBoxPublic) =>
    _hkdf.deriveKey(secretKey: shared, nonce: [...ephemeralPublic, ...recipientBoxPublic], info: utf8.encode('SXD1-envelope'));
