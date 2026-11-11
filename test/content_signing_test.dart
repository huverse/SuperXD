import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/device/relay_release_feed.dart';
import 'package:superxd/device/signed_content.dart';
import '../tool/content_signing.dart';
import '../tool/release_manifest.dart';
import 'content_signing_support.dart';

// 更新清单与开发者的话的签名（人工决策见 lib/device/signed_content.dart）：内置公钥表、信封、私钥文件与发版清单工具。
void main() {
  late TestSigning signing;
  setUpAll(() async => signing = await TestSigning.create());

  test('内置的受信公钥：三把、编号不重复、都是 32 字节；两类内容各有线上钥，离线备用钥两类都能签', () {
    expect(trustedSigningKeys, hasLength(3));
    expect({for (final key in trustedSigningKeys) key.keyId}, hasLength(3));
    expect({for (final key in trustedSigningKeys) key.publicKey}, hasLength(3));
    for (final key in trustedSigningKeys) {
      expect(keyIdPattern.hasMatch(key.keyId), isTrue, reason: key.keyId);
      expect(decodeBase64Url(key.publicKey), hasLength(32), reason: key.keyId);
    }
    Set<SignedContent> contentsOf(String prefix) => trustedSigningKeys.singleWhere((key) => key.keyId.startsWith(prefix)).contents;
    expect(contentsOf('release-'), {SignedContent.release});
    expect(contentsOf('notes-'), {SignedContent.notes});
    expect(contentsOf('offline-'), {SignedContent.release, SignedContent.notes});
  });

  test('签名原文带域前缀：同一份载荷签成开发者的话，不能当更新清单用', () async {
    final payload = utf8.encode('{"x":1}');
    final envelope = await sealSignedEnvelope(payload, SignedContent.notes, [signing.offline]);
    expect(await openSignedEnvelope(envelope, SignedContent.notes, keys: signing.keys), payload);
    await expectLater(openSignedEnvelope(envelope, SignedContent.release, keys: signing.keys), throwsA(isA<SignedEnvelopeException>().having((error) => error.reason, 'reason', 'unverified')));
    expect(utf8.decode(signedMessage(SignedContent.release, payload)), 'SXD1-release\n{"x":1}');
  });

  test('信封是外部输入：没有、不成形、签名太多都拒绝；不认识的编号跳过', () async {
    final envelope = await sealSignedEnvelope(utf8.encode('{}'), SignedContent.release, [signing.release]);
    final signature = (envelope['signatures']! as List).single as Map<String, Object?>;
    Future<String> reason(Object? envelope) async {
      try {
        await openSignedEnvelope(envelope, SignedContent.release, keys: signing.keys);
        return 'ok';
      } on SignedEnvelopeException catch (error) {
        return error.reason;
      }
    }

    expect(await reason(envelope), 'ok');
    expect(await reason(null), 'missing');
    expect(await reason('x'), 'malformed');
    expect(await reason({...envelope, 'signatures': List.filled(signedEnvelopeSignatureMax + 1, signature)}), 'malformed');
    expect(await reason({...envelope, 'signatures': [{...signature, 'keyId': 'Bad Id'}]}), 'malformed');
    expect(await reason({...envelope, 'signed': 'a+b/'}), 'malformed');
    expect(await reason({...envelope, 'signatures': [{...signature, 'keyId': 'nobody'}]}), 'unverified');
    expect(await reason({...envelope, 'signatures': [{...signature, 'keyId': 'nobody'}, signature]}), 'ok');
  });

  test('私钥文件：只认 openssl 生成的 Ed25519 PKCS#8 PEM，报错不带私钥内容', () {
    final seed = List.generate(32, (index) => index);
    const prefix = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20];
    String pem(List<int> der) => '-----BEGIN PRIVATE KEY-----\n${base64.encode(der)}\n-----END PRIVATE KEY-----\n';
    expect(seedFromPem(pem([...prefix, ...seed])), seed);
    for (final broken in [pem([...prefix, ...seed.take(31)]), pem([0x31, ...prefix.skip(1), ...seed]), 'not a key']) {
      expect(() => seedFromPem(broken), throwsA(isA<FormatException>().having((error) => error.message, 'message', isNot(contains(base64.encode(seed))))));
    }
  });

  group('发版清单（tool/release_manifest.dart）', () {
    final manifest = <String, Object?>{
      'versionCode': 27,
      'versionName': '1.0.0-alpha.16',
      'publishedAt': '2026-11-10T08:00:00Z',
      'minSupportedVersionCode': 9,
      'notes': '修了一些问题',
      'releasePage': 'https://github.com/huverse/SuperXD/releases/tag/v1.0.0-alpha.16',
      'apks': [
        for (final abi in ['arm64-v8a', 'armeabi-v7a']) {'abi': abi, 'file': 'SuperXD-1.0.0-alpha.16-$abi.apk', 'size': 1024, 'sha256': 'a' * 64},
      ],
    };

    test('每个架构各签一份：客户端按自己的架构验得过、拿到自己的安装包；明文字段原样留给旧客户端', () async {
      final signed = await signReleaseManifest(manifest, channel: 'alpha', signers: [signing.release]);
      expect({...signed}..remove('envelopes'), manifest);
      final envelopes = signed['envelopes']! as Map<String, Object?>;
      expect(envelopes.keys, releaseAbis);
      for (final abi in releaseAbis) {
        final release = await parseSignedAppRelease({'envelope': envelopes[abi]}, baseUrl: 'http://relay.test', channel: 'alpha', abi: abi, keys: signing.keys);
        expect([release.versionCode, release.minSupportedVersionCode], [27, 9]);
        // 没有这个架构的安装包时载荷里 apk 为空，客户端改用发布页。
        expect(release.apk?.url.toString(), abi == 'x86_64' ? isNull : 'http://relay.test/v1/app/files/SuperXD-1.0.0-alpha.16-$abi.apk');
        // 别的架构拿到这份（中间人换了信封）不认。
        final other = releaseAbis.firstWhere((item) => item != abi);
        await expectLater(parseSignedAppRelease({'envelope': envelopes[abi]}, baseUrl: 'http://relay.test', channel: 'alpha', abi: other, keys: signing.keys), throwsFormatException);
      }
      await expectLater(parseSignedAppRelease({'envelope': envelopes['arm64-v8a']}, baseUrl: 'http://relay.test', channel: 'beta', abi: 'arm64-v8a', keys: signing.keys), throwsFormatException);
      // 流水线签完的核对：按客户端的解析代码逐个架构验、与明文对照。
      await checkReleaseManifest(signed, channel: 'alpha', keys: signing.keys);
    });

    test('流水线的核对：受信列表里没有这把钥、换了渠道、载荷与明文不一致、缺信封，都停', () async {
      final signed = await signReleaseManifest(manifest, channel: 'alpha', signers: [signing.release]);
      await expectLater(checkReleaseManifest(signed, channel: 'alpha', keys: [for (final key in signing.keys) if (key.keyId != 'release-test') key]), throwsA(isA<SignedEnvelopeException>()));
      await expectLater(checkReleaseManifest(signed, channel: 'beta', keys: signing.keys), throwsFormatException);
      await expectLater(checkReleaseManifest({...signed, 'minSupportedVersionCode': 0}, channel: 'alpha', keys: signing.keys), throwsFormatException);
      await expectLater(checkReleaseManifest({...signed}..remove('envelopes'), channel: 'alpha', keys: signing.keys), throwsFormatException);
      final envelopes = {...signed['envelopes']! as Map<String, Object?>}..remove('x86_64');
      await expectLater(checkReleaseManifest({...signed, 'envelopes': envelopes}, channel: 'alpha', keys: signing.keys), throwsA(isA<SignedEnvelopeException>()));
    });

    test('私钥必须是源码里内置的受信公钥、且能签更新清单，对不上就不签', () async {
      await expectLater(SigningKey.fromSeed(List.filled(32, 9), SignedContent.release, keys: signing.keys), throwsFormatException);
      await expectLater(SigningKey.fromSeed(List.filled(32, 2), SignedContent.release, keys: signing.keys), throwsFormatException);
      expect((await SigningKey.fromSeed(List.filled(32, 3), SignedContent.release, keys: signing.keys)).trusted.keyId, 'offline-test');
    });

    test('更新说明写满 4000 字：三份信封加明文的文件在中转上限内，单个架构的返回在客户端上限内', () async {
      final full = {...manifest, 'notes': '字' * 4000};
      final signed = await signReleaseManifest(full, channel: 'alpha', signers: [signing.release, signing.offline]);
      expect(utf8.encode(encodeReleaseManifestFile(signed)).length, lessThanOrEqualTo(releaseManifestFileMaxBytes));
      final response = {...full, 'apk': null, 'envelope': (signed['envelopes']! as Map<String, Object?>)['arm64-v8a']}..remove('apks');
      expect(utf8.encode(jsonEncode(response)).length, lessThanOrEqualTo(appReleaseResponseMaxBytes));
    });
  });
}
