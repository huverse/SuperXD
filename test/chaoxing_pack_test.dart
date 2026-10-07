import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_credential_pack.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

const _pack = ChaoxingCredentialPack(
  phoneNumber: '13800138000',
  encryptedPassword: 'yYcVatS+4J+JGnm88UM56A==',
  name: '同学甲',
  deviceCode: 'device-code-1',
);

void main() {
  test('凭据包编解码是固定布局', () {
    final encoded = encodeChaoxingCredentialPack(_pack);
    // 版本(1) + 四个字段各自的长度(2)与内容。
    expect(encoded.first, chaoxingPackVersion);
    expect(encoded[1], 0);
    expect(encoded[2], 11);
    expect(utf8.decode(encoded.sublist(3, 14)), '13800138000');
    final decoded = decodeChaoxingCredentialPack(encoded);
    expect(decoded.phoneNumber, _pack.phoneNumber);
    expect(decoded.encryptedPassword, _pack.encryptedPassword);
    expect(decoded.name, '同学甲');
    expect(decoded.deviceCode, 'device-code-1');
  });

  test('加了密再解回来，拿错密钥或改一个字节都解不开', () async {
    final sealed = await sealChaoxingCredentialPack(_pack);
    expect(sealed.key.length, chaoxingPackKeyBytes);
    final opened = await openChaoxingCredentialPack(sealed);
    expect(opened.phoneNumber, _pack.phoneNumber);
    expect(opened.encryptedPassword, _pack.encryptedPassword);

    final otherKey = await sealChaoxingCredentialPack(_pack);
    expect(
      () => openChaoxingCredentialPack(ChaoxingSealedPack(key: otherKey.key, cipherText: sealed.cipherText)),
      throwsA(isA<ChaoxingFailure>()),
    );

    final tampered = Uint8List.fromList(sealed.cipherText);
    tampered[tampered.length - 1] ^= 1;
    expect(
      () => openChaoxingCredentialPack(ChaoxingSealedPack(key: sealed.key, cipherText: tampered)),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.invalidInput)),
    );
  });

  test('第 2 版带人脸照片，第 1 版的包照样能解', () {
    const withFaces = ChaoxingCredentialPack(
      phoneNumber: '13800138000',
      encryptedPassword: 'x',
      name: '甲',
      deviceCode: 'd',
      faceObjectIds: ['face-1', 'face_2'],
    );
    expect(decodeChaoxingCredentialPack(encodeChaoxingCredentialPack(withFaces)).faceObjectIds, ['face-1', 'face_2']);

    // 第 1 版：版本号 1，四个字段后面没有人脸照片段。
    final v2 = encodeChaoxingCredentialPack(_pack);
    final v1 = Uint8List.fromList([chaoxingPackLegacyVersion, ...v2.sublist(1, v2.length - 1)]);
    final legacy = decodeChaoxingCredentialPack(v1);
    expect(legacy.deviceCode, 'device-code-1');
    expect(legacy.faceObjectIds, isEmpty);

    for (final faces in [
      List.generate(chaoxingPackFaceLimit + 1, (index) => 'f$index'),
      ['带中文'],
      [''],
      ['x' * (chaoxingPackObjectIdMaxLength + 1)],
    ]) {
      expect(
        () => encodeChaoxingCredentialPack(
          ChaoxingCredentialPack(phoneNumber: '13800138000', encryptedPassword: 'x', name: '', deviceCode: '', faceObjectIds: faces),
        ),
        throwsA(isA<ChaoxingFailure>()),
        reason: '$faces',
      );
    }
  });

  test('两次封同一个包得到不同密文', () async {
    final first = await sealChaoxingCredentialPack(_pack);
    final second = await sealChaoxingCredentialPack(_pack);
    expect(first.key, isNot(equals(second.key)));
    expect(first.cipherText, isNot(equals(second.cipherText)));
  });

  test('坏输入按外部输入拦下', () async {
    for (final bytes in [
      <int>[],
      [chaoxingPackVersion + 1, 0, 1, 0x31],
      [chaoxingPackVersion, 0, 4, 0x31, 0x32],
      [chaoxingPackVersion, 0, 11, ...utf8.encode('1380013800'), 0, 1, 0x41, 0, 0, 0, 0],
      Uint8List(chaoxingPackMaxBytes + 1),
    ]) {
      expect(() => decodeChaoxingCredentialPack(bytes), throwsA(isA<ChaoxingFailure>()), reason: '$bytes');
    }
    // 手机号不是 11 位数字、昵称过长都要拦。
    expect(
      () => encodeChaoxingCredentialPack(const ChaoxingCredentialPack(phoneNumber: '1380013800', encryptedPassword: 'x', name: '', deviceCode: '')),
      throwsA(isA<ChaoxingFailure>()),
    );
    expect(
      () => encodeChaoxingCredentialPack(ChaoxingCredentialPack(phoneNumber: '13800138000', encryptedPassword: 'x', name: 'x' * 41, deviceCode: '')),
      throwsA(isA<ChaoxingFailure>()),
    );
    expect(
      () => openChaoxingCredentialPack(ChaoxingSealedPack(key: Uint8List(0), cipherText: Uint8List(3))),
      throwsA(isA<ChaoxingFailure>()),
    );
  });

  test('取件票二维码文本编解码', () {
    final key = chaoxingRandomBytes(chaoxingPackKeyBytes);
    final text = encodeChaoxingPackTicket(ChaoxingPackTicket(pickupId: 'AbCdEf0123456789XyZ', key: key));
    expect(text.startsWith('SXDC1:AbCdEf0123456789XyZ.'), isTrue);
    final decoded = decodeChaoxingPackTicket(text);
    expect(decoded?.pickupId, 'AbCdEf0123456789XyZ');
    expect(decoded?.key, key);

    for (final bad in ['', 'SXDC1:', 'SXDC1:short.abc', 'SXDC1:AbCdEf0123456789XyZ', 'SXDC1:AbCdEf0123456789XyZ.%%%', 'https://x/?id=1']) {
      expect(decodeChaoxingPackTicket(bad), isNull, reason: bad);
    }
    // 密钥长度不对也不认。
    expect(decodeChaoxingPackTicket('SXDC1:AbCdEf0123456789XyZ.${base64Url.encode([1, 2, 3]).replaceAll('=', '')}'), isNull);
  });
}
