import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/relay/relay_crypto.dart';

// 协议 v1 里私信自己的密码学，与服务端 server/src/common/crypto/relay_crypto.ts 逐字节一致（共用 server/test/vectors/protocol_v1.json）。
// 私信身份是 relay/relay_crypto.dart 的设备身份 RelayIdentity（Ed25519 签名密钥 + X25519 加密密钥，私钥种子只在系统安全存储里）。
// 消息：发送方用自己的签名私钥签明文，再用一次性 X25519 密钥与收件人加密公钥协商，HKDF-SHA256 派生 AES-256-GCM 密钥加密。
// 中转服务只见密文；收件人验签确认来自好友本人，附加数据绑定收件人设备号，密文不能转投给别人。

final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

const envelopeVersion = 1;
// 解压后的消息明文上限 1MB，防压缩炸弹。
const plaintextLimit = 1024 * 1024;

class SocialCryptoException implements Exception {
  const SocialCryptoException(this.message);
  final String message;
  @override
  String toString() => message;
}

Uint8List inviteProofCanonical(String inviteId, String redeemerDeviceId) => utf8.encode(['SXD1-invite', inviteId, redeemerDeviceId].join('\n'));

// 私信设备挂到应用账号的凭证原文：私信密钥对「应用账号设备号 + 私信设备号」签名（与服务端 relay_crypto.ts 的 socialBindCanonical 同一份）。
Uint8List socialBindCanonical(String accountDeviceId, String socialDeviceId) => utf8.encode(['SXD1-social-bind', accountDeviceId, socialDeviceId].join('\n'));

// 服务器给好友公钥的签名原文：「谁问的、好友设备号、两把公钥（base64url）、认得的旧设备号（没有为空）」（与服务端 relay_crypto.ts 的 friendKeysCanonical 同一份，
// 共用 server/test/vectors/protocol_v1.json 的 friendKeys；人工决策见 relay/relay_client.dart 的 relayServerKeys）。
Uint8List friendKeysCanonical(String ownerDeviceId, String deviceId, String signPublicKey, String boxPublicKey, String? movedFrom) =>
    utf8.encode(['SXD1-friend-keys', ownerDeviceId, deviceId, signPublicKey, boxPublicKey, movedFrom ?? ''].join('\n'));

// 消息签名带域前缀，签名不能被挪作请求或邀请签名使用。
Uint8List _messageCanonical(List<int> compressed) => Uint8List.fromList([...utf8.encode('SXD1-msg\n'), ...compressed]);

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
Future<Uint8List> sealEnvelope({required RelayIdentity sender, required PeerKeys recipient, required Map<String, Object?> message}) async {
  final compressed = gzip.encode(utf8.encode(jsonEncode(message)));
  final signature = await sender.sign(_messageCanonical(compressed));
  final ephemeral = await _x25519.newKeyPair();
  final ephemeralPublic = (await ephemeral.extractPublicKey()).bytes;
  final key = await _envelopeKey(await _x25519.sharedSecretKey(keyPair: ephemeral, remotePublicKey: SimplePublicKey(recipient.boxPublicKey, type: KeyPairType.x25519)), ephemeralPublic, recipient.boxPublicKey);
  final nonce = secureRandomBytes(12);
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
Future<OpenedEnvelope> openEnvelope({required RelayIdentity recipient, required List<int> envelope}) async {
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

Future<bool> verifyOpened(OpenedEnvelope opened, List<int> senderSignPublicKey) => verifyEd25519(senderSignPublicKey, opened.signed, opened.signature);

Future<SecretKey> _envelopeKey(SecretKey shared, List<int> ephemeralPublic, List<int> recipientBoxPublic) =>
    _hkdf.deriveKey(secretKey: shared, nonce: [...ephemeralPublic, ...recipientBoxPublic], info: utf8.encode('SXD1-envelope'));
