import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

// 生成应用内更新的版本清单（发版流水线 .github/workflows/release.yml 调用，也可手动运行）：读 pubspec.yaml 的版本、目录里各架构的安装包（SuperXD-<版本名>-<架构>.apk）
// 与一份面向用户的简短更新说明，算出大小与 SHA-256，写成 <渠道>.json。连同安装包传到中转服务器的 releases 目录，
// 步骤见 CONTRIBUTING.md「版本与发布」。最低可用版本平时为 0，只有旧版已无法正常使用时才调高（会逼旧版必须更新）。
// 运行：
//   dart run tool/release_manifest.dart --apks <安装包目录> --notes <更新说明.txt> --out <输出目录> [--channel alpha] [--min-supported 0]
const _abis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (var index = 0; index + 1 < args.length; index += 2) {
    options[args[index].replaceFirst('--', '')] = args[index + 1];
  }
  final apks = options['apks'], notesFile = options['notes'], out = options['out'];
  final channel = options['channel'] ?? 'alpha';
  final minSupported = int.tryParse(options['min-supported'] ?? '0');
  if (apks == null || notesFile == null || out == null || minSupported == null || minSupported < 0) {
    _fail('usage: dart run tool/release_manifest.dart --apks <dir> --notes <file> --out <dir> [--channel alpha] [--min-supported 0]');
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
  for (final abi in _abis) {
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
  final target = File('$out/$channel.json');
  await target.parent.create(recursive: true);
  await target.writeAsString('${const JsonEncoder.withIndent('  ').convert(manifest)}\n');
  stdout.writeln('[ReleaseManifest] wrote=${target.path} channel=$channel versionCode=$versionCode minSupported=$minSupported');
}

void _fail(String reason) {
  stderr.writeln('[ReleaseManifest] failed reason=$reason');
  exitCode = 2;
}
