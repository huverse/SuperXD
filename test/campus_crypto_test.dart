import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/campus_crypto.dart';

void main() {
  test('base64url 无填充：编出来不带等号，往返一致；给了长度要正好这么长', () {
    final bytes = utf8.encode('SuperXD 协议');
    final text = base64UrlNoPad(bytes);
    expect(text, isNot(contains('=')));
    expect(tryDecodeBase64UrlNoPad(text), bytes);
    expect(tryDecodeBase64UrlNoPad(text, length: bytes.length), bytes);
    expect(tryDecodeBase64UrlNoPad(text, length: bytes.length + 1), isNull);
    expect(tryDecodeBase64UrlNoPad(''), isEmpty);
  });

  test('base64url 严格解码：带填充、标准 base64 字符、非规范尾位、残缺长度与空白都拒绝', () {
    final text = base64UrlNoPad([0xfb, 0xff]);
    expect(text, '-_8');
    expect(tryDecodeBase64UrlNoPad('$text='), isNull);
    expect(tryDecodeBase64UrlNoPad('+/8'), isNull);
    // 最后一位的低位不为 0：标准解码器照收，编回去就不一样了。
    expect(tryDecodeBase64UrlNoPad('-_9'), isNull);
    expect(tryDecodeBase64UrlNoPad('AAAAA'), isNull);
    expect(tryDecodeBase64UrlNoPad(' $text'), isNull);
  });

  test('随机字节：长度对、每次不同', () {
    expect(secureRandomBytes(32), hasLength(32));
    expect(secureRandomBytes(32), isNot(secureRandomBytes(32)));
  });

  test('Ed25519 验签：对的过，改了原文、换了公钥、长度不对都不过', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(List.filled(32, 7));
    final publicKey = (await keyPair.extractPublicKey()).bytes;
    final message = utf8.encode('SXD1-test');
    final signature = (await algorithm.sign(message, keyPair: keyPair)).bytes;
    expect(await verifyEd25519(publicKey, message, signature), isTrue);
    expect(await verifyEd25519(publicKey, utf8.encode('SXD1-tesT'), signature), isFalse);
    final other = (await (await algorithm.newKeyPairFromSeed(List.filled(32, 8))).extractPublicKey()).bytes;
    expect(await verifyEd25519(other, message, signature), isFalse);
    expect(await verifyEd25519(publicKey.sublist(1), message, signature), isFalse);
    expect(await verifyEd25519(publicKey, message, signature.sublist(1)), isFalse);
  });
}
