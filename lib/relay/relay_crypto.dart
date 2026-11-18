import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

import 'package:superxd/domain/campus_crypto.dart';

// 协议 v1 里签名请求共用的那部分密码学，与服务端 server/src/common/crypto/relay_crypto.ts 逐字节一致（共用 server/test/vectors/protocol_v1.json）：
// 设备身份（Ed25519 签名密钥 + X25519 加密密钥，私钥种子只在系统安全存储里）、请求签名原文与服务器给关键回复签名的原文。
// 应用账号的设备密钥与私信身份都是这种设备身份；私信自己的信封与邀请凭证在 social/social_crypto.dart。

final _ed25519 = Ed25519();
final _x25519 = X25519();

class RelayCryptoException implements Exception {
  const RelayCryptoException(this.message);
  final String message;
  @override
  String toString() => message;
}

// 协议里的 base64url 一律无填充、规范写法（编解码与随机字节在 domain/campus_crypto.dart），不合格算外部输入坏了。
Uint8List decodeBase64UrlNoPad(String text, {int? length}) => tryDecodeBase64UrlNoPad(text, length: length) ?? (throw const RelayCryptoException('编码不正确'));

String deviceIdOf(List<int> signPublicKey) => base64UrlNoPad(hash.sha256.convert(signPublicKey).bytes.sublist(0, 16));

Uint8List requestCanonical(String method, String pathWithQuery, String time, String nonce, List<int> body) =>
    utf8.encode(['SXD1', method.toUpperCase(), pathWithQuery, time, nonce, base64UrlNoPad(hash.sha256.convert(body).bytes)].join('\n'));

// 服务器给奖品信封的签名原文：域前缀、活动编号、设备号各占一行，后面接信封签名前的全部字节（与服务端 relay_crypto.ts 的 rewardPrizeCanonical 同一份，
// 共用 server/test/vectors/reward_prize_v2.json；信封见 relay_reward_client.dart 的 openRewardPrize）。
Uint8List rewardPrizeCanonical(String campaign, String deviceId, List<int> sealed) =>
    Uint8List.fromList([...utf8.encode(['SXD1-reward-prize', campaign, deviceId, ''].join('\n')), ...sealed]);

// 服务器证明「这把设备密钥所在的应用账号已注销」的签名原文：设备号与这次请求的随机数（与服务端 relay_crypto.ts 的 accountDeletedCanonical 同一份，
// 共用 server/test/vectors/protocol_v1.json 的 accountDeleted；见 relay_client.dart 的 request）。
Uint8List accountDeletedCanonical(String deviceId, String nonce) => utf8.encode(['SXD1-account-deleted', deviceId, nonce].join('\n'));

Future<Uint8List> signWithSeed(List<int> seed, List<int> message) async {
  final signature = await _ed25519.sign(message, keyPair: await _ed25519.newKeyPairFromSeed(seed));
  return Uint8List.fromList(signature.bytes);
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
class RelayIdentity {
  RelayIdentity._(this.signSeed, this.boxSeed, this.signPublicKey, this.boxPublicKey) : deviceId = deviceIdOf(signPublicKey);
  final Uint8List signSeed;
  final Uint8List boxSeed;
  final Uint8List signPublicKey;
  final Uint8List boxPublicKey;
  final String deviceId;

  static Future<RelayIdentity> fromSeeds(List<int> signSeed, List<int> boxSeed) async {
    if (signSeed.length != 32 || boxSeed.length != 32) throw const RelayCryptoException('身份密钥不完整');
    return RelayIdentity._(Uint8List.fromList(signSeed), Uint8List.fromList(boxSeed), await ed25519PublicOf(signSeed), await x25519PublicOf(boxSeed));
  }

  static Future<RelayIdentity> generate() => fromSeeds(secureRandomBytes(32), secureRandomBytes(32));

  Future<Uint8List> sign(List<int> message) => signWithSeed(signSeed, message);
}
