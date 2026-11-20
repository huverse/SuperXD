import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:superxd/device/signed_content.dart';
import 'package:superxd/toolbox/cinema/cinema_catalog_file.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';

import 'content_signing.dart';

// 电影院的片源规则包（人工决策见 lib/toolbox/cinema/cinema_service.dart 文件头：中转下发、不进公开仓库）：维护者电脑上的私有文件
// （默认 ~/.local/share/superxd-cinema/rules.json）签成中转用的 cinema.json（{"version": 1, "envelope": 信封}，载荷是规则包的确切字节），
// 由 tool/cinema_publish.sh 调用后传到中转，客户端打开电影院时拉取（两次至少隔一小时），不用发版。
// 规则包写法见 lib/toolbox/cinema/cinema_rule.dart（Kazumi 的 API 模式规则加 id、海报年份备注路径与 parsers），version 每次发布加一（客户端只升不降）。
// 签名：--signing-key 可以给多把，每把都必须是源码里能签 cinema 的受信公钥（信件那把钥或离线备用钥）。
// 片名目录型的源（catalogRules，人工决策见 lib/toolbox/cinema/cinema_catalog.dart）：私有文件里 catalog 写 path（本机底包，tool/cinema_catalog.dart 抓的），
// 这里读出它的 SHA-256、大小与首行的抓取起点，换成 file（cinema-<id>-<哈希前 12 位>.tsv.gz）、sha256、bytes、builtAt 签进去；给了 --catalog-dir 时把底包按这个名字拷过去等上传。
// 运行：dart run tool/cinema_rules.dart [--in <文件>]                                         只检查格式
//       dart run tool/cinema_rules.dart [--in <文件>] --out <cinema.json> --signing-key <私钥.pem> [--catalog-dir <目录>]   生成签好的一份
String defaultCinemaSource() => '${Platform.environment['HOME']}/.local/share/superxd-cinema/rules.json';

// 规则包按客户端同一份解码检查；写出的载荷是去掉缩进的 JSON（字节小、签名对它签）。catalogs 是要随包上传的底包（本机路径与发布名）。
Future<({CinemaPackage package, List<int> payload, List<({String path, String file})> catalogs})> readCinemaRules(File file) async {
  final raw = jsonDecode(await file.readAsString());
  final catalogs = <({String path, String file})>[];
  if (raw is Map && raw['catalogRules'] is List) {
    for (final rule in (raw['catalogRules'] as List).whereType<Map<String, Object?>>()) {
      final catalog = rule['catalog'];
      if (catalog is! Map || catalog['path'] is! String) continue;
      final path = (catalog['path'] as String).replaceFirst(RegExp(r'^~'), Platform.environment['HOME'] ?? '~');
      final bytes = await File(path).readAsBytes();
      final digest = sha256.convert(bytes).toString();
      final decoded = decodeCinemaCatalog(bytes, digest);
      final name = 'cinema-${rule['id']}-${digest.substring(0, 12)}.tsv.gz';
      catalog
        ..remove('path')
        ..['file'] = name
        ..['sha256'] = digest
        ..['bytes'] = bytes.length
        ..['builtAt'] = decoded.builtAt.toIso8601String();
      catalogs.add((path: path, file: name));
    }
  }
  final payload = utf8.encode(jsonEncode(raw));
  return (package: decodeCinemaPackage(payload), payload: payload, catalogs: catalogs);
}

Future<String> encodeCinemaFile(List<int> payload, List<SigningKey> signers) async =>
    jsonEncode({'version': 1, 'envelope': await sealSignedEnvelope(payload, SignedContent.cinema, signers)});

Future<void> main(List<String> args) async {
  String? option(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final source = option('--in') ?? defaultCinemaSource(), out = option('--out'), catalogDir = option('--catalog-dir');
  final signingKeys = [for (var index = 0; index + 1 < args.length; index++) if (args[index] == '--signing-key') args[index + 1]];
  if (out != null && signingKeys.isEmpty || out == null && signingKeys.isNotEmpty) {
    stderr.writeln('usage: dart run tool/cinema_rules.dart [--in <file>] [--out <cinema.json> --signing-key <pem> [--signing-key <pem>]]');
    exitCode = 64;
    return;
  }
  try {
    final (:package, :payload, :catalogs) = await readCinemaRules(File(source));
    if (out == null) {
      stdout.writeln('[CinemaRules] action=check version=${package.version} rules=${package.rules.length} catalogs=${catalogs.length} parsers=${package.parsers.length} bytes=${payload.length}');
      return;
    }
    final signers = [for (final path in signingKeys) await SigningKey.fromPemFile(path, SignedContent.cinema)];
    await File(out).writeAsString(await encodeCinemaFile(payload, signers));
    for (final catalog in catalogs) {
      if (catalogDir != null) await File(catalog.path).copy('$catalogDir/${catalog.file}');
      stdout.writeln('[CinemaRules] action=catalog file=${catalog.file}');
    }
    stdout.writeln('[CinemaRules] action=build version=${package.version} rules=${package.rules.length} keyIds=${signers.map((signer) => signer.trusted.keyId).join(',')}');
  } on PathNotFoundException {
    stderr.writeln('没有规则包文件 $source（用 --in 指定，或先建这个文件）');
    exitCode = 1;
  } on CinemaRuleException catch (error) {
    stderr.writeln('[CinemaRules] failed reason=${error.message}');
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}
