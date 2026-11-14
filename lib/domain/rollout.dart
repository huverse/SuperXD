import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:superxd/domain/challenge.dart';

// [人工决策-2026-11-13 22:06:22] 灰度与分批更新（分批更新用户选「自动分阶段」，灰度的做法是助手定的、说过用户没反对）：
// - 分桶：sha256("SXD1-rollout\n" + 开关 + "\n" + 主体) 前 4 字节当无符号整数，乘 10000 除以 2^32 取整，得 0–9999；放量 p% 时桶号小于 p×100 的在批次里。
//   同一开关同一主体桶号不变，放量只涨不跌时进了批次的一直在里面。服务端 server/src/common/rollout_bucket.ts 是同一个函数，共用 server/test/vectors/rollout_v1.json。
// - 主体：登录了应用账号用账号号，没登录用本机随机编号（不上传，见 application/rollouts.dart）；登录后可能换一次桶。
// - 配置像开发者的话一样由流水线签名下发（仓库 rollout/rollout.json → 中转 /v1/app/rollout），客户端在本机判定，服务器不知道谁拿到了什么。
// - 分批更新：发版时清单里写放量表（从发布时刻起每天一档，默认 20%→50%→100%），客户端按当前时刻算；配置里同名的开关
//   （appUpdateRolloutId）可以覆盖成定值（暂停就写成当时的百分比，直接全量写 100）。自动检查按批次，手动检查不受限（同苹果的分阶段发布），
//   必须更新（低于最低可用版本）不受批次限制。
// [人工决策-2026-11-14 20:20:18] 灰度按积分等级加权（用户选「按等级自动加权」，等级规则见服务端 src/modules/points/points_level.ts）：不用报名，
// Lv0 到 Lv5 的倍数 1.0、1.4、1.8、2.2、2.6、3.0（1 + 2 × 等级 ÷ 5，封顶 3 倍），桶号小于「放量 × 100 × 倍数」的在批次里；
// 只因等级进的批次本机记住（application/rollouts.dart），积分过期降级也不踢出；放量写 0 仍人人关，一键关停不受等级影响。

class RolloutStage {
  const RolloutStage({required this.from, required this.percent});
  // 这一档从什么时刻起（UTC）。
  final DateTime from;
  // 0–100 的整数。
  final int percent;
}

// 一个开关：定值（percent）或按时刻的放量表（stages），两者只有一个。
class RolloutRule {
  const RolloutRule({required this.id, this.percent, this.stages = const []});
  final String id;
  final int? percent;
  final List<RolloutStage> stages;

  // 此刻放量多少：定值直接用；放量表取开始时刻不晚于此刻的最后一档，还没开始为 0。
  int percentAt(DateTime now) {
    final fixed = percent;
    if (fixed != null) return fixed;
    var current = 0;
    for (final stage in stages) {
      if (!stage.from.isAfter(now)) current = stage.percent;
    }
    return current;
  }
}

class RolloutConfig {
  const RolloutConfig(this.rules, {this.levels = const []});
  final Map<String, RolloutRule> rules;
  // 积分等级 Lv0–Lv5 的门槛（近 12 个月获得的积分，[人工决策-2026-11-14 20:20:18] 见服务端 src/modules/points/points_level.ts）：
  // 跟着灰度配置下发，服务端算等级读同一份；没写为空。
  final List<int> levels;
  static const empty = RolloutConfig({});
}

// 上限：开关最多 200 个、每个放量表最多 20 档（与 tool/rollout_config.dart、服务端 relay_limits.ts 的文件上限一起管住配置的体积）。
const rolloutRuleLimit = 200;
const rolloutStageLimit = 20;
final rolloutIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

int rolloutBucket(String id, String subject) {
  final digest = sha256.convert(utf8.encode('SXD1-rollout\n$id\n$subject')).bytes;
  final value = (digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3];
  return value * 10000 ~/ 0x100000000;
}

// level 是积分等级 0–5：门槛用整数算（放量 × 20 × (5 + 2 × 等级)，即放量 × 100 × 倍数），免得小数误差多放或少放一个桶。
bool rolloutIncludes(String id, String subject, int percent, {int level = 0}) => rolloutBucket(id, subject) < min(10000, percent * 20 * (5 + 2 * level));

// 分批更新用的开关名：渠道加版本号，每个版本各分一次桶（每次先拿到更新的不总是同一批人）。
String appUpdateRolloutId(String channel, int versionCode) => 'app_update.$channel.$versionCode';

int _percent(Object? value) => switch (value) {
  final int percent when percent >= 0 && percent <= 100 => percent,
  _ => throw const FormatException('percent 不合法'),
};

// 放量表是外部输入（验过签的配置或清单载荷）：每档开始时刻带时区、按时间先后、百分比只增不减，最后一档不必是 100（还没放完）。
List<RolloutStage> decodeRolloutStages(Object? json) {
  if (json is! List || json.isEmpty || json.length > rolloutStageLimit) throw const FormatException('stages 不合法');
  final stages = <RolloutStage>[];
  for (final item in json) {
    if (item case {'from': final String from, 'percent': final Object? percent} when item.length == 2) {
      final at = DateTime.tryParse(from);
      if (at == null || !(from.endsWith('Z') || RegExp(r'[+-]\d\d:\d\d$').hasMatch(from))) throw const FormatException('from 要带时区');
      final stage = RolloutStage(from: at.toUtc(), percent: _percent(percent));
      if (stages.isNotEmpty && (!stage.from.isAfter(stages.last.from) || stage.percent < stages.last.percent)) throw const FormatException('放量表要按时间先后、只增不减');
      stages.add(stage);
    } else {
      throw const FormatException('stage 不合法');
    }
  }
  return stages;
}

// 等级门槛：正好六档、从 0 起、严格递增（同服务端 rollout_source.ts）。
List<int> _levels(Object? json) {
  if (json is! List || json.length != pointsLevelCount) throw const FormatException('levels 要是六个数');
  final levels = [for (final item in json) item is int && item >= 0 ? item : throw const FormatException('levels 要是非负整数')];
  for (var index = 0; index < levels.length; index++) {
    if (index == 0 ? levels[0] != 0 : levels[index] <= levels[index - 1]) throw const FormatException('levels 要从 0 起严格递增');
  }
  return levels;
}

// 灰度配置 {flags: [{id, percent} 或 {id, stages}], levels?: [六个数]} 是外部输入：逐项校验，开关名不能重复，多出来的字段不认。
RolloutConfig decodeRolloutConfig(Object? json) {
  if (json case {'flags': final List<Object?> flags} when flags.length <= rolloutRuleLimit && json.keys.every((key) => key == 'flags' || key == 'levels')) {
    final rules = <String, RolloutRule>{};
    for (final flag in flags) {
      final rule = switch (flag) {
        {'id': final String id, 'percent': final Object? percent} when flag.length == 2 && rolloutIdPattern.hasMatch(id) => RolloutRule(id: id, percent: _percent(percent)),
        {'id': final String id, 'stages': final Object? stages} when flag.length == 2 && rolloutIdPattern.hasMatch(id) => RolloutRule(id: id, stages: decodeRolloutStages(stages)),
        _ => throw const FormatException('开关不合法'),
      };
      if (rules.containsKey(rule.id)) throw FormatException('开关 ${rule.id} 重复');
      rules[rule.id] = rule;
    }
    return RolloutConfig(rules, levels: json.containsKey('levels') ? _levels(json['levels']) : const []);
  }
  throw const FormatException('灰度配置不合法');
}

// 本机存一份上次拉到的配置（同解码的格式，读回来再走一遍 decodeRolloutConfig）。
Map<String, Object?> encodeRolloutConfig(RolloutConfig config) => {
  'flags': [
    for (final rule in config.rules.values)
      if (rule.percent case final percent?)
        {'id': rule.id, 'percent': percent}
      else
        {'id': rule.id, 'stages': [for (final stage in rule.stages) {'from': stage.from.toUtc().toIso8601String(), 'percent': stage.percent}]},
  ],
  if (config.levels.isNotEmpty) 'levels': config.levels,
};

// 拉配置失败，message 只记日志（灰度配置没有界面）。
class RolloutException implements Exception {
  const RolloutException(this.message);
  final String message;
  @override
  String toString() => 'RolloutException($message)';
}

// 灰度配置的拉取端口（device 实现）：只认验签通过的内容；中转还没放过配置时给空配置。
abstract interface class RolloutFeed {
  Future<RolloutConfig> fetch();
}

// 本机记录（local 实现）：这台设备的随机编号（没登录应用账号时分桶用，不上传）、上次拉到的配置与时刻；
// 另记当前主体（应用账号号）上次取到的积分等级与只因等级才进的批次（最多 rolloutRuleLimit 个，旧的先丢），换了主体从头记。
abstract interface class RolloutMemory {
  String get installId;
  RolloutConfig get config;
  DateTime? get fetchedAt;
  Future<void> save(RolloutConfig config, DateTime fetchedAt);
  int levelOf(String subject);
  bool joined(String subject, String id);
  Future<void> saveLevel(String subject, int level);
  Future<void> join(String subject, String id);
}
