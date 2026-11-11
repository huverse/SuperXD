import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'package:superxd/device/diagnostic_seal.dart';

// 解开用户上传的诊断包（人工决策见 lib/domain/diagnostic_upload.dart），解出的就是开发者选项「导出日志」的那个 zip。只读写本机文件、不联网，不打印私钥与包的内容。
// 解开（仓库根目录）：
//   dart run tool/open_diagnostic.dart <密文文件> <私钥文件> [输出的 zip]
//   输出默认是密文文件名加 .zip，已存在就不覆盖。密文在中转服务器上，取法见 server/README.md「部署」的诊断包一条（docker compose cp 出来再拷回本机）。
//   私钥文件是一行 base64url 的 32 字节 X25519 私钥，只放开发者本机（~/.local/share/superxd-signing/diagnostic_x25519.key，权限 600），不进仓库与 GitHub 机密。
// 换密钥：
//   dart run tool/open_diagnostic.dart --generate <新私钥文件>
//   私钥文件先建成 600 再写入（已存在就不写），只打印公钥；把公钥写进 lib/device/diagnostic_seal.dart 的 diagnosticRecipientKey 并发版，之前上传的包仍要用旧私钥解。
Future<void> main(List<String> args) async {
  switch (args) {
    case ['--generate', final keyPath]:
      await _generate(File(keyPath));
    case [final sealedPath, final keyPath, ...final rest] when rest.length <= 1 && !sealedPath.startsWith('--'):
      await _open(File(sealedPath), File(keyPath), File(rest.firstOrNull ?? '$sealedPath.zip'));
    default:
      _fail('usage=dart run tool/open_diagnostic.dart <密文文件> <私钥文件> [输出的zip] | --generate <新私钥文件>');
  }
}

Future<void> _open(File sealed, File key, File output) async {
  if (await output.exists()) return _fail('reason=output_exists path=${output.path}');
  try {
    final zip = await openDiagnostic(await sealed.readAsBytes(), decodeDiagnosticKey((await key.readAsString()).trim()));
    await output.writeAsBytes(zip, flush: true);
    stdout.writeln('[OpenDiagnostic] wrote=${output.path} bytes=${zip.length}');
  } on FormatException catch (error) {
    _fail('reason=${error.message}');
  }
}

Future<void> _generate(File key) async {
  if (await key.exists()) return _fail('reason=key_exists path=${key.path}');
  final keyPair = await X25519().newKeyPair();
  // 先建空文件改成 600 再写私钥：私钥没有一刻是别人可读的。
  await key.create(recursive: true, exclusive: true);
  final chmod = await Process.run('chmod', ['600', key.path]);
  if (chmod.exitCode != 0) {
    await key.delete();
    return _fail('reason=chmod_failed');
  }
  await key.writeAsString('${encodeDiagnosticKey(await keyPair.extractPrivateKeyBytes())}\n', flush: true);
  stdout.writeln('[OpenDiagnostic] generated=${key.path} publicKey=${encodeDiagnosticKey((await keyPair.extractPublicKey()).bytes)}');
}

void _fail(String detail) {
  stderr.writeln('[OpenDiagnostic] failed $detail');
  exitCode = 1;
}
