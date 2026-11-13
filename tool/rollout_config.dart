import 'dart:convert';
import 'dart:io';

import 'package:superxd/device/signed_content.dart';
import 'package:superxd/domain/rollout.dart';

import 'content_signing.dart';

// 灰度配置（人工决策见 lib/domain/rollout.dart）：把仓库 rollout/rollout.json 整理成中转用的 rollout.json。
// rollout 目录有改动合并到 main 时由流水线 .github/workflows/rollout.yml 调用并上传，客户端联网拉取，不用发版；CI 的 test/rollout_test.dart
// 会把仓库里的配置读一遍，格式不对的 PR 合并不了。
// 仓库里的写法 {"flags": [...]}，每个开关一项：
//   {"id": "某功能", "percent": 10}                                   定值：10% 的人打开（0 关停、100 全开）
//   {"id": "某功能", "stages": [{"from": "2026-11-20T00:00:00+08:00", "percent": 20}, ...]}   按时刻放量，只增不减
//   {"id": "app_update.alpha.28", "percent": 50}                      覆盖这一版更新清单的放量表：暂停写当时的百分比，直接全量写 100，整版关停写 0
// 签名：载荷是整理后的 {"flags": [...]} 的确切字节，签好放进 envelope，中转原样透传，客户端只认它；--signing-key 可以给多把，每把都必须是源码里能签 rollout 的受信公钥。
// 运行：dart run tool/rollout_config.dart                                  只检查格式
//       dart run tool/rollout_config.dart --out <文件> --signing-key <私钥.pem>   生成签好的文件（流水线用）
// 明文一份加签名载荷一份不超过 64KB；中转与客户端同一上限（server/src/common/relay_limits.ts 的 rolloutFileMaxBytes）。
const rolloutFileMaxBytes = 64 * 1024;

Future<RolloutConfig> readRolloutConfig(File file) async {
  if (!await file.exists()) return RolloutConfig.empty;
  return decodeRolloutConfig(jsonDecode(await file.readAsString()));
}

Future<String> encodeRolloutFile(RolloutConfig config, List<SigningKey> signers) async {
  final plain = encodeRolloutConfig(config);
  final envelope = await sealSignedEnvelope(utf8.encode(jsonEncode(plain)), SignedContent.rollout, signers);
  final json = jsonEncode({...plain, 'envelope': envelope});
  final bytes = utf8.encode(json).length;
  if (bytes > rolloutFileMaxBytes) throw FormatException('配置 $bytes 字节，超过中转的上限 $rolloutFileMaxBytes');
  return json;
}

Future<void> main(List<String> args) async {
  final out = args.length >= 4 && args[0] == '--out' ? args[1] : null;
  final signingKeys = [for (var index = 2; index + 1 < args.length; index += 2) if (args[index] == '--signing-key') args[index + 1]];
  if (args.isNotEmpty && (out == null || signingKeys.isEmpty || signingKeys.length * 2 + 2 != args.length)) {
    stderr.writeln('usage: dart run tool/rollout_config.dart [--out <file> --signing-key <pem> [--signing-key <pem>]]');
    exitCode = 64;
    return;
  }
  try {
    final config = await readRolloutConfig(File('rollout/rollout.json'));
    if (out == null) {
      stdout.writeln('[RolloutConfig] action=check flags=${config.rules.length}');
      return;
    }
    final signers = [for (final path in signingKeys) await SigningKey.fromPemFile(path, SignedContent.rollout)];
    await File(out).writeAsString(await encodeRolloutFile(config, signers));
    stdout.writeln('[RolloutConfig] action=build flags=${config.rules.length} keyIds=${signers.map((signer) => signer.trusted.keyId).join(',')}');
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}
