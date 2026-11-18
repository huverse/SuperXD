import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/challenge.dart';

// [人工决策-2026-11-13 22:06:22] 灰度与分批更新（分批更新用户选「自动分阶段」，灰度的做法是助手定的、说过用户没反对）：
// - 分桶：sha256("SXD1-rollout\n" + 开关 + "\n" + 主体) 前 4 字节当无符号整数，乘 10000 除以 2^32 取整，得 0–9999；放量 p% 时桶号小于 p×100 的在批次里。
//   同一开关同一主体桶号不变，放量只涨不跌时进了批次的一直在里面。服务端 server/src/common/rollout_bucket.ts 是同一个函数，共用 server/test/vectors/rollout_v1.json。
// - 主体：登录了应用账号用账号号，没登录用本机随机编号（不上传，见 application/rollouts.dart）；登录后可能换一次桶。
// - 配置像开发者的话一样签名下发（11-13 时是仓库 rollout/rollout.json 经流水线，11-16 起改本机签名上传，见下面 20:04 那条），客户端在本机判定。
// - 分批更新：发版时清单里写放量表（从发布时刻起每天一档，默认 20%→50%→100%），客户端按当前时刻算；配置里同名的开关
//   （appUpdateRolloutId）可以覆盖成定值（暂停就写成当时的百分比，直接全量写 100）。自动检查按批次，手动检查不受限（同苹果的分阶段发布），
//   必须更新（低于最低可用版本）不受批次限制。
// [人工决策-2026-11-14 20:20:18] 灰度按积分等级加权（用户选「按等级自动加权」，等级规则见服务端 src/modules/points/points_level.ts）：不用报名，
// Lv0 到 Lv5 的倍数 1.0、1.4、1.8、2.2、2.6、3.0（1 + 2 × 等级 ÷ 5，封顶 3 倍），桶号小于「放量 × 100 × 倍数」的在批次里；
// 只因等级进的批次本机记住（application/rollouts.dart），积分过期降级也不踢出；放量写 0 仍人人关，一键关停不受等级影响。

// [人工决策-2026-11-16 17:05:21] 灰度改「混合判定」（用户选定，原话要求灰度能随时发放、随时撤销，任何功能、逻辑、界面都能灰度，参数可定义如预设时间）：
// - 比例与条件在本机判定：开关可另写时间窗 from/until（过了 until 全关）、平台、渠道、安装的版本号区间、最低积分等级、应用账号建立满几天与参数 params（命中时功能读它）；
//   新功能只经 domain/feature_flags.dart 登记的开关问 Rollouts，不散落字符串。
// - 点名在服务器判定：开发者用中转的管理命令 flag_admin 把开关单独开给某个应用账号（名单只在服务器、不进公开配置），登录着应用账号的手机
//   随拉配置同一时机签名问「我被点名了哪些」（RolloutTargetClient），点名的开关不看比例与条件、只看到期时刻；撤销后下次问就没了。
// - 第 2 版配置走 /v1/app/flags（只有签名信封），第 1 版 /v1/app/rollout 留给 alpha.28 及以前（它们的解码多一个字段就整份拒收），
//   第 1 版只放没有新字段的开关，带条件的开关旧版本按各自默认值。
// [人工决策-2026-11-16 20:04:01] 公共配置的签名改由本机工具签后上传（用户选定，取代 11-13 那条里「仓库 rollout/rollout.json 由流水线签名下发」）：
// 配置放维护者电脑上的私有目录、不进公开仓库（看仓库就知道在灰度什么），tool/rollout_config.dart 用信件那把钥签出两份、tool/rollout_publish.sh 传中转；私钥不上服务器。
class RolloutStage {
  const RolloutStage({required this.from, required this.percent});
  // 这一档从什么时刻起（UTC）。
  final DateTime from;
  // 0–100 的整数。
  final int percent;
}

// 一个开关：定值（percent）或按时刻的放量表（stages），两者只有一个；另可写条件（都满足才按比例判定）与命中时给的参数。
class RolloutRule {
  const RolloutRule({required this.id, this.percent, this.stages = const [], this.from, this.until, this.platforms = const {}, this.channels = const {}, this.minVersion, this.maxVersion, this.minLevel, this.minAccountDays, this.params = const {}});
  final String id;
  final int? percent;
  final List<RolloutStage> stages;
  // 时间窗（UTC）：from 之前、until 之后都关。
  final DateTime? from, until;
  // 平台（android、ios）与渠道（构建渠道，如 alpha）：为空不限。
  final Set<String> platforms, channels;
  // 安装的版本号（构建号）区间，含两端；为空不限。
  final int? minVersion, maxVersion;
  // 积分等级至少多少（娱乐与积分关着按 Lv0）。
  final int? minLevel;
  // 应用账号建立满多少天（没登录应用账号、还没问到建立时刻的都不满足）。
  final int? minAccountDays;
  // 命中时给功能读的参数：键是小写开头的英文，值是字符串、整数、小数或布尔。
  final Map<String, Object> params;

  // 带第 2 版才有的字段：第 1 版配置里放不下（旧版本解码多一个字段就整份拒收）。
  bool get conditional => from != null || until != null || platforms.isNotEmpty || channels.isNotEmpty || minVersion != null || maxVersion != null || minLevel != null || minAccountDays != null || params.isNotEmpty;

  // 条件都满足：在时间窗里、平台渠道对得上、版本号在区间里、等级够、账号建立的天数够（accountDays 为空是不知道）。
  bool applies({required DateTime now, required String platform, required String channel, required int versionCode, required int level, int? accountDays}) =>
      (from == null || !now.isBefore(from!)) &&
      (until == null || now.isBefore(until!)) &&
      (platforms.isEmpty || platforms.contains(platform)) &&
      (channels.isEmpty || channels.contains(channel)) &&
      (minVersion == null || versionCode >= minVersion!) &&
      (maxVersion == null || versionCode <= maxVersion!) &&
      (minLevel == null || level >= minLevel!) &&
      (minAccountDays == null || (accountDays != null && accountDays >= minAccountDays!));

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

// 一项解锁（[人工决策-2026-11-14 20:20:18] 规则见服务端 src/modules/unlock/unlock_rules.ts）：编号用约定前缀（game.<游戏 id> 新游戏抢先玩、
// toolbox.<工具 id> 隐藏的工具），title 是积分页上的名字；等级门槛、价格、抽签比例、公开时刻满足任一就开，retired 是下架（谁都不能用，买过的退回积分）。
class RolloutUnlock {
  const RolloutUnlock({required this.id, required this.title, this.minLevel, this.price, this.percent, this.publicAt, this.retired = false});
  final String id, title;
  final int? minLevel, price, percent;
  final DateTime? publicAt;
  final bool retired;

  bool isPublic(DateTime now) => switch (publicAt) {
    final at? => !at.isAfter(now),
    null => false,
  };
}

const rolloutUnlockLimit = 100;
const rolloutUnlockTitleMax = 20;
const rolloutUnlockPriceMax = 100000;

class RolloutConfig {
  const RolloutConfig(this.rules, {this.levels = const [], this.unlocks = const [], this.paused = const {}});
  final Map<String, RolloutRule> rules;
  // 健康回报自动暂停的分批更新（app_update.<渠道>.<版本号>，人工决策见 domain/app_health.dart）：中转不签名地附在第 2 版回复里，
  // 只拿来少提示（自动检查不提示这一版），被冒充最多让人晚点更新；不进签名载荷、旧版视图不带。
  final Set<String> paused;
  // 积分等级 Lv0–Lv5 的门槛（近 12 个月获得的积分，[人工决策-2026-11-14 20:20:18] 见服务端 src/modules/points/points_level.ts）：
  // 跟着灰度配置下发，服务端算等级读同一份；没写为空。
  final List<int> levels;
  final List<RolloutUnlock> unlocks;
  static const empty = RolloutConfig({});

  // 给第 1 版接口（alpha.28 及以前）的那份：去掉带新字段的开关，等级门槛与解锁照旧。
  RolloutConfig get legacy => RolloutConfig({for (final rule in rules.values) if (!rule.conditional) rule.id: rule}, levels: levels, unlocks: unlocks);

  RolloutConfig withPaused(Set<String> paused) => RolloutConfig(rules, levels: levels, unlocks: unlocks, paused: paused);
}

// 问点名的回复（人工决策见文件头 11-16 那条）：点名的开关与这个应用账号建立的时刻（判 minAccountDays 用）。
class RolloutTargets {
  const RolloutTargets({required this.flags, required this.accountCreatedAt});
  final List<RolloutTarget> flags;
  final DateTime accountCreatedAt;
}

// 点名：开发者在服务器上把这个开关单独开给当前应用账号，until 为空是一直开到撤销。
class RolloutTarget {
  const RolloutTarget(this.id, {this.until});
  final String id;
  final DateTime? until;

  bool activeAt(DateTime now) => until == null || now.isBefore(until!);
}

// 点名的上限：同开关数（服务端 relay_limits.ts 的 flagTargetLimit）。
const rolloutTargetLimit = rolloutRuleLimit;

// 中转返回的点名列表是外部输入：编号合规、不重复、到期时刻与账号建立时刻带时区，超过上限拒收。本机记录也用这个格式。
RolloutTargets decodeRolloutTargets(Object? json) {
  if (json case {'flags': final List<Object?> flags, 'accountCreatedAt': final String createdAt} when flags.length <= rolloutTargetLimit) {
    final targets = <RolloutTarget>[];
    for (final item in flags) {
      if (item case {'id': final String id, 'until': final Object? until} when rolloutIdPattern.hasMatch(id) && targets.every((other) => other.id != id)) {
        targets.add(RolloutTarget(id, until: switch (until) {
          null => null,
          final String text => _instant(text, 'until'),
          _ => throw const FormatException('until 不合法'),
        }));
      } else {
        throw const FormatException('点名不合法');
      }
    }
    return RolloutTargets(flags: targets, accountCreatedAt: _instant(createdAt, 'accountCreatedAt'));
  }
  throw const FormatException('点名列表不合法');
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

const _unlockKeys = {'id', 'title', 'minLevel', 'price', 'percent', 'publicAt', 'retired'};

int? _range(Object? value, int min, int max, String what) => switch (value) {
  null => null,
  final int number when number >= min && number <= max => number,
  _ => throw FormatException('$what 要在 $min–$max'),
};

// 解锁：编号不重复；没下架的至少写一个条件；下架只认 true（同服务端 rollout_source.ts）。
List<RolloutUnlock> _unlocks(Object? json) {
  if (json is! List || json.length > rolloutUnlockLimit) throw const FormatException('unlocks 不合法');
  final unlocks = <RolloutUnlock>[];
  for (final item in json) {
    if (item case {'id': final String id, 'title': final String title} when item.keys.every(_unlockKeys.contains) && rolloutIdPattern.hasMatch(id) && title.isNotEmpty && title.length <= rolloutUnlockTitleMax) {
      final publicAt = switch (item['publicAt']) {
        null => null,
        final String text when text.endsWith('Z') || RegExp(r'[+-]\d\d:\d\d$').hasMatch(text) => DateTime.tryParse(text)?.toUtc() ?? (throw const FormatException('publicAt 不合法')),
        _ => throw const FormatException('publicAt 要带时区'),
      };
      if (!(item['retired'] == null || item['retired'] == true)) throw const FormatException('retired 只能写 true');
      final unlock = RolloutUnlock(
        id: id,
        title: title,
        minLevel: _range(item['minLevel'], 1, pointsLevelCount - 1, 'minLevel'),
        price: _range(item['price'], 1, rolloutUnlockPriceMax, 'price'),
        percent: _range(item['percent'], 1, 100, 'percent'),
        publicAt: publicAt,
        retired: item['retired'] == true,
      );
      if (!unlock.retired && unlock.minLevel == null && unlock.price == null && unlock.percent == null && unlock.publicAt == null) throw FormatException('解锁 $id 一个条件也没写');
      if (unlocks.any((other) => other.id == id)) throw FormatException('解锁 $id 重复');
      unlocks.add(unlock);
    } else {
      throw const FormatException('解锁不合法');
    }
  }
  return unlocks;
}

// 时刻要带时区（Z 或 ±hh:mm），存成 UTC。
DateTime _instant(String text, String what) {
  final at = DateTime.tryParse(text);
  if (at == null || !(text.endsWith('Z') || RegExp(r'[+-]\d\d:\d\d$').hasMatch(text))) throw FormatException('$what 要带时区');
  return at.toUtc();
}

// 条件与参数的上限：参数最多 rolloutParamLimit 项、字符串最长 rolloutParamTextMax 字；平台只有 android、ios；渠道同开关编号的写法。
const rolloutParamLimit = 20;
const rolloutParamTextMax = 200;
const rolloutPlatforms = {'android', 'ios'};
final _paramKey = RegExp(r'^[a-z][a-zA-Z0-9_]{0,31}$');
const _flagKeys = {'id', 'percent', 'stages', 'from', 'until', 'platforms', 'channels', 'minVersion', 'maxVersion', 'minLevel', 'minAccountDays', 'params'};

Set<String> _names(Object? json, bool Function(String name) valid, String what) => switch (json) {
  null => const {},
  final List<Object?> list when list.isNotEmpty && list.length <= 8 && list.every((item) => item is String && valid(item)) => {for (final item in list) item as String},
  _ => throw FormatException('$what 不合法'),
};

Map<String, Object> _params(Object? json) {
  if (json == null) return const {};
  if (json is! Map || json.isEmpty || json.length > rolloutParamLimit) throw const FormatException('params 不合法');
  final params = <String, Object>{};
  for (final MapEntry(:key, :value) in json.entries) {
    if (key is! String || !_paramKey.hasMatch(key)) throw FormatException('参数名 $key 不合法');
    params[key] = switch (value) {
      final String text when text.length <= rolloutParamTextMax => text,
      final int number => number,
      final double number when number.isFinite => number,
      final bool flag => flag,
      _ => throw FormatException('参数 $key 不合法'),
    };
  }
  return params;
}

RolloutRule _rule(Object? flag) {
  if (flag case {'id': final String id} when rolloutIdPattern.hasMatch(id) && flag.keys.every(_flagKeys.contains) && flag.containsKey('percent') != flag.containsKey('stages')) {
    final from = flag['from'] is String ? _instant(flag['from'] as String, 'from') : flag['from'] == null ? null : throw const FormatException('from 不合法');
    final until = flag['until'] is String ? _instant(flag['until'] as String, 'until') : flag['until'] == null ? null : throw const FormatException('until 不合法');
    if (from != null && until != null && !until.isAfter(from)) throw FormatException('开关 $id 的 until 要晚于 from');
    final minVersion = _range(flag['minVersion'], 1, 1 << 30, 'minVersion'), maxVersion = _range(flag['maxVersion'], 1, 1 << 30, 'maxVersion');
    if (minVersion != null && maxVersion != null && minVersion > maxVersion) throw FormatException('开关 $id 的版本区间不合法');
    return RolloutRule(
      id: id,
      percent: flag.containsKey('percent') ? _percent(flag['percent']) : null,
      stages: flag.containsKey('stages') ? decodeRolloutStages(flag['stages']) : const [],
      from: from,
      until: until,
      platforms: _names(flag['platforms'], rolloutPlatforms.contains, 'platforms'),
      channels: _names(flag['channels'], rolloutIdPattern.hasMatch, 'channels'),
      minVersion: minVersion,
      maxVersion: maxVersion,
      minLevel: _range(flag['minLevel'], 0, pointsLevelCount - 1, 'minLevel'),
      minAccountDays: _range(flag['minAccountDays'], 1, 3650, 'minAccountDays'),
      params: _params(flag['params']),
    );
  }
  throw const FormatException('开关不合法');
}

// 灰度配置 {flags: [...], levels?: [六个数], unlocks?: [...]} 是外部输入：逐项校验，开关名不能重复，多出来的字段不认。
// 每个开关 {id, percent 或 stages, 另可写 from、until、platforms、channels、minVersion、maxVersion、minLevel、minAccountDays、params}（第 2 版；第 1 版只有前两项）。
// version 只是给人看的写法版本，可写可不写（第 1 版接口发出去的那份不写，旧版本见了会拒收）。
RolloutConfig decodeRolloutConfig(Object? json) {
  const keys = {'version', 'flags', 'levels', 'unlocks', 'paused'};
  if (json case {'flags': final List<Object?> flags} when flags.length <= rolloutRuleLimit && json.keys.every(keys.contains) && (json['version'] == null || json['version'] == 1 || json['version'] == 2)) {
    final rules = <String, RolloutRule>{};
    for (final flag in flags) {
      final rule = _rule(flag);
      if (rules.containsKey(rule.id)) throw FormatException('开关 ${rule.id} 重复');
      rules[rule.id] = rule;
    }
    return RolloutConfig(rules, levels: json.containsKey('levels') ? _levels(json['levels']) : const [], unlocks: json.containsKey('unlocks') ? _unlocks(json['unlocks']) : const [], paused: decodeRolloutPaused(json['paused']));
  }
  throw const FormatException('灰度配置不合法');
}

// 本机存一份上次拉到的配置，第 1 版接口的那份也用它写（同解码的格式，读回来再走一遍 decodeRolloutConfig）；没写的字段不出现。
Map<String, Object?> encodeRolloutConfig(RolloutConfig config) => {
  'flags': [
    for (final rule in config.rules.values)
      {
        'id': rule.id,
        if (rule.percent case final percent?) 'percent': percent else 'stages': [for (final stage in rule.stages) {'from': stage.from.toUtc().toIso8601String(), 'percent': stage.percent}],
        if (rule.from case final from?) 'from': from.toUtc().toIso8601String(),
        if (rule.until case final until?) 'until': until.toUtc().toIso8601String(),
        if (rule.platforms.isNotEmpty) 'platforms': [...rule.platforms],
        if (rule.channels.isNotEmpty) 'channels': [...rule.channels],
        'minVersion': ?rule.minVersion,
        'maxVersion': ?rule.maxVersion,
        'minLevel': ?rule.minLevel,
        'minAccountDays': ?rule.minAccountDays,
        if (rule.params.isNotEmpty) 'params': rule.params,
      },
  ],
  if (config.levels.isNotEmpty) 'levels': config.levels,
  if (config.paused.isNotEmpty) 'paused': [...config.paused],
  if (config.unlocks.isNotEmpty)
    'unlocks': [
      for (final unlock in config.unlocks)
        {
          'id': unlock.id,
          'title': unlock.title,
          'minLevel': ?unlock.minLevel,
          'price': ?unlock.price,
          'percent': ?unlock.percent,
          'publicAt': ?unlock.publicAt?.toUtc().toIso8601String(),
          if (unlock.retired) 'retired': true,
        },
    ],
};

// 自动暂停的名单是外部输入：只认分批更新的开关名，最多 rolloutRuleLimit 个，不合格的整份不用（当没有暂停）。
Set<String> decodeRolloutPaused(Object? json) => switch (json) {
  final List<Object?> items when items.length <= rolloutRuleLimit && items.every((item) => item is String && item.startsWith('app_update.') && rolloutIdPattern.hasMatch(item)) => {...items.cast<String>()},
  _ => const {},
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
  // 当前主体（应用账号号）上次问到的点名与账号建立的时刻；换了主体为空。
  List<RolloutTarget> targetsOf(String subject);
  DateTime? accountCreatedOf(String subject);
  Future<void> saveTargets(String subject, RolloutTargets targets);
}

// 问中转「当前应用账号被点名了哪些」（relay 实现，用这个账号的设备密钥签名）；没登录或账号不在了为空，连不上抛 RolloutException。
abstract interface class RolloutTargetClient {
  Future<RolloutTargets?> mine(AppAccountRef account);
}
