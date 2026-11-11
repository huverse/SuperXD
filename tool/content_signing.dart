import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:superxd/device/relay_note_feed.dart';
import 'package:superxd/device/relay_release_feed.dart';
import 'package:superxd/device/signed_content.dart';
import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/developer_note.dart';

// 更新清单与开发者的话的签名与核对（人工决策见 lib/device/signed_content.dart）。release_manifest.dart、developer_notes.dart 用它签名；
// 流水线签完再用它的 check-release、check-notes 按客户端源码里内置的公钥与客户端的解析代码验一遍，对不上就停。
// 私钥是 PKCS#8 PEM（openssl genpkey -algorithm ed25519 生成），放在仓库外；这里只读文件，不打印私钥的任何部分。
// 运行：
//   dart run tool/content_signing.dart check-release <清单.json> --channel alpha
//   dart run tool/content_signing.dart check-notes <developer_notes.json>
//   dart run tool/content_signing.dart public-key <私钥.pem>      换钥时取新钥的公钥，写进 lib/device/signed_content.dart
const releaseAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

final _ed25519 = Ed25519();

// openssl 生成的 Ed25519 私钥 DER 固定 48 字节：前 16 字节是版本与算法标识，后 32 字节是私钥种子。
const _pkcs8Ed25519Prefix = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20];

List<int> seedFromPem(String text) {
  final body = RegExp(r'-----BEGIN PRIVATE KEY-----([A-Za-z0-9+/=\s]+)-----END PRIVATE KEY-----').firstMatch(text)?[1];
  if (body == null) throw const FormatException('私钥不是 PKCS#8 PEM');
  final der = base64.decode(body.replaceAll(RegExp(r'\s'), ''));
  if (der.length != 48 || [for (var index = 0; index < 16; index++) der[index] == _pkcs8Ed25519Prefix[index]].contains(false)) {
    throw const FormatException('私钥不是 Ed25519');
  }
  return der.sublist(16);
}

Future<String> publicKeyOfSeed(List<int> seed) async => base64UrlNoPad((await (await _ed25519.newKeyPairFromSeed(seed)).extractPublicKey()).bytes);

// 一把能用的签名钥：私钥种子推出的公钥必须是源码里内置的那一把、且能签这类内容，否则拒绝（机密里的私钥和源码对不上就停）。
class SigningKey {
  SigningKey._(this.trusted, this._seed);
  final TrustedSigningKey trusted;
  final List<int> _seed;

  static Future<SigningKey> fromSeed(List<int> seed, SignedContent content, {List<TrustedSigningKey> keys = trustedSigningKeys}) async {
    final publicKey = await publicKeyOfSeed(seed);
    final trusted = keys.where((key) => key.publicKey == publicKey).firstOrNull;
    if (trusted == null) throw const FormatException('这把私钥的公钥不在 lib/device/signed_content.dart 的受信列表里');
    if (!trusted.contents.contains(content)) throw FormatException('${trusted.keyId} 不能签 ${content.name}');
    return SigningKey._(trusted, seed);
  }

  static Future<SigningKey> fromPemFile(String path, SignedContent content, {List<TrustedSigningKey> keys = trustedSigningKeys}) async =>
      fromSeed(seedFromPem(await File(path).readAsString()), content, keys: keys);
}

// 对载荷原样的字节签名，每把钥一个签名。
Future<Map<String, Object>> sealSignedEnvelope(List<int> payload, SignedContent content, List<SigningKey> signers) async {
  if (signers.isEmpty || signers.length > signedEnvelopeSignatureMax) throw FormatException('签名钥要 1 到 $signedEnvelopeSignatureMax 把');
  final message = signedMessage(content, payload);
  return {
    'signed': base64UrlNoPad(payload),
    'signatures': [
      for (final signer in signers)
        {
          'keyId': signer.trusted.keyId,
          'sig': base64UrlNoPad((await _ed25519.sign(message, keyPair: await _ed25519.newKeyPairFromSeed(signer._seed))).bytes),
        },
    ],
  };
}

// 按中转的做法给每个架构拼出返回（明文字段加这个架构的信封），交给客户端的解析代码：每个架构都要验得过，且与明文字段一致。
Future<void> checkReleaseManifest(Map<String, Object?> manifest, {required String channel, String baseUrl = 'http://relay.invalid', List<TrustedSigningKey> keys = trustedSigningKeys}) async {
  final envelopes = manifest['envelopes'];
  final apks = manifest['apks'];
  if (envelopes is! Map || apks is! List) throw const FormatException('清单没有 envelopes 或 apks');
  for (final abi in releaseAbis) {
    final response = {...manifest, 'envelope': envelopes[abi]}
      ..remove('envelopes')
      ..remove('apks');
    final release = await parseSignedAppRelease(response, baseUrl: baseUrl, channel: channel, abi: abi, keys: keys);
    final apk = apks.whereType<Map<String, Object?>>().where((item) => item['abi'] == abi).firstOrNull;
    final same = release.versionCode == manifest['versionCode'] &&
        release.versionName == manifest['versionName'] &&
        release.publishedAt == DateTime.parse(manifest['publishedAt']! as String) &&
        release.minSupportedVersionCode == manifest['minSupportedVersionCode'] &&
        release.notes == manifest['notes'] &&
        release.releasePage.toString() == manifest['releasePage'] &&
        (apk == null
            ? release.apk == null
            : release.apk?.url.toString() == '$baseUrl/v1/app/files/${apk['file']}' && release.apk?.size == apk['size'] && release.apk?.sha256 == apk['sha256']);
    if (!same) throw FormatException('$abi 签名载荷与明文字段不一致');
    // iOS 取 arm64 那份、不要安装包。
    if (abi == 'arm64-v8a') await parseSignedAppRelease(response, baseUrl: baseUrl, channel: channel, abi: abi, packages: false, keys: keys);
    stdout.writeln('[ContentSigning] action=check_release abi=$abi versionCode=${release.versionCode} keyIds=${_keyIds(envelopes[abi])}');
  }
}

// 签好的文件必须带信封（中转上没放文件时的「空列表不带信封」只是服务端的返回，不是签好的文件）；验得过且与明文一致。
Future<void> checkDeveloperNotes(Map<String, Object?> file, {List<TrustedSigningKey> keys = trustedSigningKeys}) async {
  if (file['envelope'] == null) throw const FormatException('开发者的话没有签名信封');
  final signed = await decodeSignedDeveloperNotes(file, keys: keys);
  final plain = decodeDeveloperNotes(file);
  String digest(List<DeveloperNote> notes) => jsonEncode(encodeDeveloperNotes(notes));
  if (digest(signed) != digest(plain)) throw const FormatException('签名载荷与明文 notes 不一致');
  stdout.writeln('[ContentSigning] action=check_notes count=${signed.length} keyIds=${_keyIds(file['envelope'])}');
}

String _keyIds(Object? envelope) => switch (envelope) {
  {'signatures': final List<Object?> signatures} => [for (final item in signatures) if (item case {'keyId': final String keyId}) keyId].join(','),
  _ => '',
};

Future<void> main(List<String> args) async {
  try {
    switch (args) {
      case ['check-release', final path, '--channel', final channel]:
        await checkReleaseManifest(jsonDecode(await File(path).readAsString()) as Map<String, Object?>, channel: channel);
      case ['check-notes', final path]:
        await checkDeveloperNotes(jsonDecode(await File(path).readAsString()) as Map<String, Object?>);
      case ['public-key', final path]:
        stdout.writeln(await publicKeyOfSeed(seedFromPem(await File(path).readAsString())));
      default:
        stderr.writeln('usage: dart run tool/content_signing.dart check-release <file> --channel <channel> | check-notes <file> | public-key <pem>');
        exitCode = 64;
    }
  } on FormatException catch (error) {
    stderr.writeln('[ContentSigning] failed reason=${error.message}');
    exitCode = 1;
  } on SignedEnvelopeException catch (error) {
    stderr.writeln('[ContentSigning] failed errorType=SignedEnvelopeException reason=${error.reason}');
    exitCode = 1;
  }
}
