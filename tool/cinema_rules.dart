import 'dart:convert';
import 'dart:io';

import 'package:superxd/device/signed_content.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';

import 'content_signing.dart';

// 电影院的片源规则包（人工决策见 lib/toolbox/cinema/cinema_service.dart 文件头：中转下发、不进公开仓库）：维护者电脑上的私有文件
// （默认 ~/.local/share/superxd-cinema/rules.json）签成中转用的 cinema.json（{"version": 1, "envelope": 信封}，载荷是规则包的确切字节），
// 由 tool/cinema_publish.sh 调用后传到中转，客户端打开电影院时拉取（两次至少隔一小时），不用发版。
// 规则包写法见 lib/toolbox/cinema/cinema_rule.dart（Kazumi 的 API 模式规则加 id、海报年份备注路径与 parsers），version 每次发布加一（客户端只升不降）。
// 签名：--signing-key 可以给多把，每把都必须是源码里能签 cinema 的受信公钥（信件那把钥或离线备用钥）。
// 运行：dart run tool/cinema_rules.dart [--in <文件>]                                         只检查格式
//       dart run tool/cinema_rules.dart [--in <文件>] --out <cinema.json> --signing-key <私钥.pem>   生成签好的一份
String defaultCinemaSource() => '${Platform.environment['HOME']}/.local/share/superxd-cinema/rules.json';

// 规则包按客户端同一份解码检查；写出的载荷是去掉缩进的 JSON（字节小、签名对它签）。
Future<({CinemaPackage package, List<int> payload})> readCinemaRules(File file) async {
  final payload = utf8.encode(jsonEncode(jsonDecode(await file.readAsString())));
  return (package: decodeCinemaPackage(payload), payload: payload);
}

Future<String> encodeCinemaFile(List<int> payload, List<SigningKey> signers) async =>
    jsonEncode({'version': 1, 'envelope': await sealSignedEnvelope(payload, SignedContent.cinema, signers)});

Future<void> main(List<String> args) async {
  String? option(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final source = option('--in') ?? defaultCinemaSource(), out = option('--out');
  final signingKeys = [for (var index = 0; index + 1 < args.length; index++) if (args[index] == '--signing-key') args[index + 1]];
  if (out != null && signingKeys.isEmpty || out == null && signingKeys.isNotEmpty) {
    stderr.writeln('usage: dart run tool/cinema_rules.dart [--in <file>] [--out <cinema.json> --signing-key <pem> [--signing-key <pem>]]');
    exitCode = 64;
    return;
  }
  try {
    final (:package, :payload) = await readCinemaRules(File(source));
    if (out == null) {
      stdout.writeln('[CinemaRules] action=check version=${package.version} rules=${package.rules.length} parsers=${package.parsers.length} bytes=${payload.length}');
      return;
    }
    final signers = [for (final path in signingKeys) await SigningKey.fromPemFile(path, SignedContent.cinema)];
    await File(out).writeAsString(await encodeCinemaFile(payload, signers));
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
