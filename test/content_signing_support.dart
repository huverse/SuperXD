import 'dart:convert';

import 'package:superxd/device/signed_content.dart';

import '../tool/content_signing.dart';

// 测试用的签名钥：固定种子，公钥只进测试里的受信列表（lib 里内置的是真钥的公钥，私钥不在仓库）。
// 三把的分工同真钥：发版清单、开发者的话与灰度配置、离线备用（三类都能签）；stranger 不在受信列表里。
class TestSigning {
  TestSigning._(this.keys, this.release, this.notes, this.rollout, this.offline, this.stranger);
  final List<TrustedSigningKey> keys;
  final SigningKey release;
  final SigningKey notes;
  // 开发者的话那把钥签灰度配置。
  final SigningKey rollout;
  final SigningKey offline;
  // 自称是受信的 release-test（keyId 冒名），其实是另一把钥。
  final SigningKey stranger;

  static Future<TestSigning> create() async {
    final releaseSeed = List.filled(32, 1), notesSeed = List.filled(32, 2), offlineSeed = List.filled(32, 3), strangerSeed = List.filled(32, 9);
    final keys = [
      TrustedSigningKey('release-test', await publicKeyOfSeed(releaseSeed), {SignedContent.release}),
      TrustedSigningKey('notes-test', await publicKeyOfSeed(notesSeed), {SignedContent.notes, SignedContent.rollout}),
      TrustedSigningKey('offline-test', await publicKeyOfSeed(offlineSeed), {SignedContent.release, SignedContent.notes, SignedContent.rollout}),
    ];
    final impostor = [TrustedSigningKey('release-test', await publicKeyOfSeed(strangerSeed), {SignedContent.release, SignedContent.notes})];
    return TestSigning._(
      keys,
      await SigningKey.fromSeed(releaseSeed, SignedContent.release, keys: keys),
      await SigningKey.fromSeed(notesSeed, SignedContent.notes, keys: keys),
      await SigningKey.fromSeed(notesSeed, SignedContent.rollout, keys: keys),
      await SigningKey.fromSeed(offlineSeed, SignedContent.release, keys: keys),
      await SigningKey.fromSeed(strangerSeed, SignedContent.release, keys: impostor),
    );
  }

  Future<Map<String, Object>> seal(Map<String, Object?> payload, SignedContent content, List<SigningKey> signers) =>
      sealSignedEnvelope(utf8.encode(jsonEncode(payload)), content, signers);
}
