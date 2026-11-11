import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:superxd/device/signed_content.dart';

import 'content_signing.dart';

// 生成应用内更新的版本清单（发版流水线 .github/workflows/release.yml 调用，也可手动运行）：读 pubspec.yaml 的版本、目录里各架构的安装包（SuperXD-<版本名>-<架构>.apk）
// 与一份面向用户的简短更新说明，算出大小与 SHA-256，写成 <渠道>.json。连同安装包传到中转服务器的 releases 目录，
// 步骤见 CONTRIBUTING.md「版本与发布」。最低可用版本平时为 0，只有旧版已无法正常使用时才调高（会逼旧版必须更新）。
// 签名（人工决策见 lib/device/signed_content.dart）：中转按架构挑安装包后重新拼返回，所以每个架构各签一份载荷（渠道、架构、版本、
// 最低可用版本、更新说明、发布页与这个架构的安装包），放进 envelopes，中转原样透传；新客户端只认它。顶层的明文字段与 apks
// 留给 1.0.0-alpha.15 及以前不验签的旧客户端。--signing-key 可以给多把（换钥时新旧各签一份），每把都必须是源码里内置的受信公钥。
// 运行：
//   dart run tool/release_manifest.dart --apks <安装包目录> --notes <更新说明.txt> --out <输出目录> --signing-key <私钥.pem> [--channel alpha] [--min-supported 0]
// 中转按 128KB 封顶读清单文件（server/src/common/relay_limits.ts 的 appReleaseFileMaxBytes）：三份信封加明文，更新说明写满 4000 字也不到 70KB。
const releaseManifestFileMaxBytes = 128 * 1024;

// 一个架构的签名载荷：字段顺序固定，签的是 jsonEncode 出来的确切字节。
Map<String, Object?> releasePayload({
  required String channel,
  required String abi,
  required Map<String, Object?> manifest,
  required Map<String, Object?>? apk,
}) => {
  'channel': channel,
  'abi': abi,
  'versionCode': manifest['versionCode'],
  'versionName': manifest['versionName'],
  'publishedAt': manifest['publishedAt'],
  'minSupportedVersionCode': manifest['minSupportedVersionCode'],
  'notes': manifest['notes'],
  'releasePage': manifest['releasePage'],
  'apk': apk == null ? null : {'file': apk['file'], 'size': apk['size'], 'sha256': apk['sha256']},
};

// 明文清单加每个架构各一份信封；没有这个架构的安装包时载荷里 apk 为空（客户端改用发布页）。
Future<Map<String, Object?>> signReleaseManifest(Map<String, Object?> manifest, {required String channel, required List<SigningKey> signers}) async {
  final apks = (manifest['apks']! as List).cast<Map<String, Object?>>();
  return {
    ...manifest,
    'envelopes': {
      for (final abi in releaseAbis)
        abi: await sealSignedEnvelope(
          utf8.encode(jsonEncode(releasePayload(channel: channel, abi: abi, manifest: manifest, apk: apks.where((item) => item['abi'] == abi).firstOrNull))),
          SignedContent.release,
          signers,
        ),
    },
  };
}

String encodeReleaseManifestFile(Map<String, Object?> manifest) {
  final json = '${const JsonEncoder.withIndent('  ').convert(manifest)}\n';
  final bytes = utf8.encode(json).length;
  if (bytes > releaseManifestFileMaxBytes) throw FormatException('清单 $bytes 字节，超过中转的上限 $releaseManifestFileMaxBytes');
  return json;
}

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  final signingKeys = <String>[];
  for (var index = 0; index + 1 < args.length; index += 2) {
    if (args[index] == '--signing-key') {
      signingKeys.add(args[index + 1]);
    } else {
      options[args[index].replaceFirst('--', '')] = args[index + 1];
    }
  }
  final apks = options['apks'], notesFile = options['notes'], out = options['out'];
  final channel = options['channel'] ?? 'alpha';
  final minSupported = int.tryParse(options['min-supported'] ?? '0');
  if (apks == null || notesFile == null || out == null || signingKeys.isEmpty || minSupported == null || minSupported < 0) {
    _fail('usage: dart run tool/release_manifest.dart --apks <dir> --notes <file> --out <dir> --signing-key <pem> [--signing-key <pem>] [--channel alpha] [--min-supported 0]');
    return;
  }
  final version = RegExp(r'^version:\s*(\S+)\+(\d+)\s*$', multiLine: true).firstMatch(await File('pubspec.yaml').readAsString());
  if (version == null) {
    _fail('pubspec.yaml 里没有「版本名+构建号」格式的 version');
    return;
  }
  final versionName = version[1]!, versionCode = int.parse(version[2]!);
  final notes = (await File(notesFile).readAsString()).trim();
  if (notes.isEmpty || notes.length > 4000) {
    _fail('更新说明要有内容且不超过 4000 字，现在 ${notes.length} 字');
    return;
  }
  final packages = <Map<String, Object>>[];
  for (final abi in releaseAbis) {
    final file = File('$apks/SuperXD-$versionName-$abi.apk');
    if (!await file.exists()) {
      stdout.writeln('[ReleaseManifest] skip abi=$abi reason=missing file=${file.path}');
      continue;
    }
    final digest = await sha256.bind(file.openRead()).first;
    packages.add({'abi': abi, 'file': file.uri.pathSegments.last, 'size': await file.length(), 'sha256': digest.toString()});
    stdout.writeln('[ReleaseManifest] abi=$abi size=${await file.length()} sha256=$digest');
  }
  if (packages.isEmpty) {
    _fail('目录里一个安装包都没有');
    return;
  }
  final manifest = {
    'versionCode': versionCode,
    'versionName': versionName,
    'publishedAt': DateTime.now().toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z'),
    'minSupportedVersionCode': minSupported,
    'notes': notes,
    'releasePage': 'https://github.com/huverse/SuperXD/releases/tag/v$versionName',
    'apks': packages,
  };
  final String json;
  try {
    final signers = [for (final path in signingKeys) await SigningKey.fromPemFile(path, SignedContent.release)];
    json = encodeReleaseManifestFile(await signReleaseManifest(manifest, channel: channel, signers: signers));
    stdout.writeln('[ReleaseManifest] action=sign keyIds=${signers.map((signer) => signer.trusted.keyId).join(',')}');
  } on FormatException catch (error) {
    _fail(error.message);
    return;
  }
  final target = File('$out/$channel.json');
  await target.parent.create(recursive: true);
  await target.writeAsString(json);
  stdout.writeln('[ReleaseManifest] wrote=${target.path} channel=$channel versionCode=$versionCode minSupported=$minSupported');
}

void _fail(String reason) {
  stderr.writeln('[ReleaseManifest] failed reason=$reason');
  exitCode = 2;
}
