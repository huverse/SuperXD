import 'dart:convert';
import 'dart:io';

import 'package:superxd/device/signed_content.dart';
import 'package:superxd/domain/rollout.dart';

import 'content_signing.dart';

// 灰度配置（人工决策见 lib/domain/rollout.dart 文件头 11-16 那两条）：维护者电脑上的私有文件（不进公开仓库，默认 ~/.local/share/superxd-rollout/rollout.json）
// 整理成中转用的两份：flags.json（第 2 版，只有签名信封，新版本客户端读 /v1/app/flags）与 rollout.json（第 1 版，明文加信封，只放没有新字段的开关，
// alpha.28 及以前读 /v1/app/rollout）。由 tool/rollout_publish.sh 调用后传到中转，客户端联网拉取，不用发版。
// 私有文件的写法 {"flags": [...], "levels": [...], "unlocks": [...]}，每个开关一项：
//   {"id": "某功能", "percent": 10}                                   定值：10% 的人打开（0 关停、100 全开）
//   {"id": "某功能", "stages": [{"from": "2026-11-20T00:00:00+08:00", "percent": 20}, ...]}   按时刻放量，只增不减
//   另可加条件与参数（第 2 版才有，旧版本按默认值）："from"、"until"（带时区的时刻，过了 until 全关）、"platforms": ["android"]、
//     "channels": ["alpha"]、"minVersion": 29、"maxVersion": 40（安装的构建号区间）、"minLevel": 2（积分等级至少）、"minAccountDays": 7（应用账号建立满几天）、"params": {"limit": 3}（命中时功能读）
//   {"id": "app_update.alpha.28", "percent": 50}                      覆盖这一版更新清单的放量表：暂停写当时的百分比，直接全量写 100，整版关停写 0
// "levels" 是积分等级 Lv0–Lv5 的门槛（规则见服务端 src/modules/points/points_level.ts），"unlocks" 是解锁清单（规则见服务端 src/modules/unlock/unlock_rules.ts）。
// 开关编号要在 lib/domain/feature_flags.dart 登记（应用更新的 app_update.* 除外）；点名单个应用账号不写在这里，用中转的 flag_admin（见 server/README.md）。
// 签名：载荷是整理后配置的确切字节，--signing-key 可以给多把，每把都必须是源码里能签 rollout 的受信公钥（信件那把钥或离线备用钥）。
// 运行：dart run tool/rollout_config.dart [--in <文件>]                                                只检查格式
//       dart run tool/rollout_config.dart [--in <文件>] --out-dir <目录> --signing-key <私钥.pem>      生成签好的两份
// 每份不超过 64KB；中转与客户端同一上限（server/src/common/relay_limits.ts 的 rolloutFileMaxBytes）。
const rolloutFileMaxBytes = 64 * 1024;

String defaultRolloutSource() => '${Platform.environment['HOME']}/.local/share/superxd-rollout/rollout.json';

Future<RolloutConfig> readRolloutConfig(File file) async => decodeRolloutConfig(jsonDecode(await file.readAsString()));

String _bounded(Map<String, Object?> json) {
  final text = jsonEncode(json);
  final bytes = utf8.encode(text).length;
  if (bytes > rolloutFileMaxBytes) throw FormatException('配置 $bytes 字节，超过中转的上限 $rolloutFileMaxBytes');
  return text;
}

// 第 1 版（/v1/app/rollout）：明文加信封，只放没有新字段的开关（旧版本的解码多一个字段就整份拒收）。
Future<String> encodeRolloutFile(RolloutConfig config, List<SigningKey> signers) async {
  final plain = encodeRolloutConfig(config.legacy);
  final envelope = await sealSignedEnvelope(utf8.encode(jsonEncode(plain)), SignedContent.rollout, signers);
  return _bounded({...plain, 'envelope': envelope});
}

// 第 2 版（/v1/app/flags）：只有签名信封，载荷是整份配置。
Future<String> encodeFlagsFile(RolloutConfig config, List<SigningKey> signers) async {
  final envelope = await sealSignedEnvelope(utf8.encode(jsonEncode({'version': 2, ...encodeRolloutConfig(config)})), SignedContent.rollout, signers);
  return _bounded({'version': 2, 'envelope': envelope});
}

Future<void> main(List<String> args) async {
  String? option(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final source = option('--in') ?? defaultRolloutSource(), outDir = option('--out-dir');
  final signingKeys = [for (var index = 0; index + 1 < args.length; index++) if (args[index] == '--signing-key') args[index + 1]];
  if (outDir != null && signingKeys.isEmpty || outDir == null && signingKeys.isNotEmpty) {
    stderr.writeln('usage: dart run tool/rollout_config.dart [--in <file>] [--out-dir <dir> --signing-key <pem> [--signing-key <pem>]]');
    exitCode = 64;
    return;
  }
  try {
    final config = await readRolloutConfig(File(source));
    if (outDir == null) {
      stdout.writeln('[RolloutConfig] action=check flags=${config.rules.length} legacy=${config.legacy.rules.length} levels=${config.levels.length} unlocks=${config.unlocks.length}');
      return;
    }
    final signers = [for (final path in signingKeys) await SigningKey.fromPemFile(path, SignedContent.rollout)];
    await File('$outDir/rollout.json').writeAsString(await encodeRolloutFile(config, signers));
    await File('$outDir/flags.json').writeAsString(await encodeFlagsFile(config, signers));
    stdout.writeln('[RolloutConfig] action=build flags=${config.rules.length} legacy=${config.legacy.rules.length} keyIds=${signers.map((signer) => signer.trusted.keyId).join(',')}');
  } on PathNotFoundException {
    stderr.writeln('没有灰度配置文件 $source（用 --in 指定，或先建这个文件）');
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}
