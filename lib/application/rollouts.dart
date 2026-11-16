import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/domain/rollout.dart';

// 灰度的编排 Rollouts（设备级，人工决策见 domain/rollout.dart）：用本机存着的配置在本机判定；配置在同意协议与政策之后、回到前台时拉，
// 两次至少隔 refreshGap，失败照旧用上次的。分桶的主体是当前应用账号的账号号，没登录用本机随机编号（不上传）。
// 登录着应用账号时同一时机取一次积分等级（level，经挑战与积分的签名请求），按等级加权；只因等级才进的批次记在本机，降级也不踢出。
// levelsOn 为假（娱乐与积分关着，人工决策见 domain/leisure.dart）时不取等级、按 Lv0 判定，已经因等级进了的批次照旧算。
// 11-16 起（人工决策见 domain/rollout.dart 文件头 11-16 那条）：开关的条件（时间窗、平台、渠道、版本号、等级）都满足才按比例判定；
// 登录着应用账号时同一时机问一次点名（targets），点名的开关不看比例与条件、只看到期时刻，问到的记在本机（换账号从头记）。
class Rollouts extends ChangeNotifier {
  Rollouts({required this.memory, required this.channel, required this.platform, required this.versionCode, required this._accountId, this.feed, this.level, this.targets, bool Function()? levelsOn, DateTime Function()? now})
    : _levelsOn = levelsOn ?? (() => true),
      _now = now ?? DateTime.now;
  final RolloutMemory memory;
  // 构建渠道（如 alpha），分批更新的开关名带上它，开关的 channels 条件也按它。
  final String channel;
  // 平台（android、ios）与安装的版本号（构建号），开关的 platforms 与版本区间条件按它们。
  final String platform;
  final int versionCode;
  // 当前应用账号被点名了哪些；没登录、没配中转时为空（照旧用本机记着的）。
  final Future<List<RolloutTarget>?> Function()? targets;
  // 没配中转时为空：只用本机存着的配置（一般是空的），开关都按各自的默认值。
  final RolloutFeed? feed;
  // 当前应用账号的积分等级；没登录或这次取不到为空（照旧用本机记着的）。没配中转时整个为空。
  final Future<int?> Function()? level;
  final String? Function() _accountId;
  final bool Function() _levelsOn;
  final DateTime Function() _now;

  static const refreshGap = Duration(hours: 1);
  bool _fetching = false;

  String get subject => _accountId() ?? memory.installId;

  // 本机存着的配置（解锁的清单也在里面，见 application/unlocks.dart）；拉到新配置时 notifyListeners。
  RolloutConfig get config => memory.config;

  // 功能开关：被点名（没到期）的直接开；配置里有就看条件、再按放量判定，没有用调用方给的默认值（新功能默认关、要关停的老功能默认开）。
  bool enabled(String id, {required bool fallback}) {
    final now = _now();
    if (memory.targetsOf(subject).any((target) => target.id == id && target.activeAt(now))) return true;
    final rule = memory.config.rules[id];
    if (rule == null) return fallback;
    if (!rule.applies(now: now, platform: platform, channel: channel, versionCode: versionCode, level: _levelsOn() ? memory.levelOf(subject) : 0)) return false;
    return _includes(id, rule.percentAt(now));
  }

  // 登记过的功能开关（domain/feature_flags.dart）：功能只经它们问。
  bool isOn(FeatureFlag flag) => enabled(flag.id, fallback: flag.fallback);

  // 开着时配置给这个开关的参数；没开、没写这一项为空（点名开的也读配置里的参数）。
  Object? param(FeatureFlag flag, String key) => isOn(flag) ? memory.config.rules[flag.id]?.params[key] : null;

  // 分批更新：配置里同名开关覆盖清单的放量表（暂停、直接全量、整版关停）；清单没写放量表又没覆盖时就是全量。
  bool inUpdateBatch(AppRelease release) {
    final id = appUpdateRolloutId(channel, release.versionCode);
    final rule = memory.config.rules[id] ?? (release.rollout.isEmpty ? null : RolloutRule(id: id, stages: release.rollout));
    return rule == null || _includes(id, rule.percentAt(_now()));
  }

  // 不看等级就在批次里的直接算；只因等级才进的记下来，以后降级也照旧在里面；放量为 0 谁都不在。
  bool _includes(String id, int percent) {
    final subject = this.subject;
    if (percent == 0) return false;
    if (rolloutIncludes(id, subject, percent) || memory.joined(subject, id)) return true;
    if (!_levelsOn() || !rolloutIncludes(id, subject, percent, level: memory.levelOf(subject))) return false;
    unawaited(memory.join(subject, id).catchError((Object error, StackTrace stack) => campusLog('[Rollouts] action=join errorType=${error.runtimeType}\n$stack')));
    return true;
  }

  Future<void> refresh() async {
    final source = feed, fetchedAt = memory.fetchedAt;
    if (source == null || _fetching || (fetchedAt != null && _now().difference(fetchedAt) < refreshGap)) return;
    _fetching = true;
    try {
      final config = await source.fetch();
      await memory.save(config, _now());
      campusLog('[Rollouts] action=refresh rules=${config.rules.length}');
      notifyListeners();
    } on RolloutException catch (error) {
      campusLog('[Rollouts] action=refresh errorType=RolloutException message=${error.message}');
    } catch (error, stack) {
      campusLog('[Rollouts] action=refresh errorType=${error.runtimeType}\n$stack');
    } finally {
      _fetching = false;
    }
    await _refreshLevel();
    await _refreshTargets();
  }

  // 问一次点名：没登录或这次问不到时照旧用记着的；问到了（含空列表，即全撤销了）就记下，变了通知。
  Future<void> _refreshTargets() async {
    final source = targets;
    if (source == null || _accountId() == null) return;
    final subject = this.subject;
    try {
      final current = await source();
      if (current == null || subject != this.subject) return;
      final before = memory.targetsOf(subject).map((target) => '${target.id}@${target.until}').join(',');
      await memory.saveTargets(subject, current);
      campusLog('[Rollouts] action=targets count=${current.length}');
      if (current.map((target) => '${target.id}@${target.until}').join(',') != before) notifyListeners();
    } on RolloutException catch (error) {
      campusLog('[Rollouts] action=targets errorType=RolloutException message=${error.message}');
    } catch (error, stack) {
      campusLog('[Rollouts] action=targets errorType=${error.runtimeType}\n$stack');
    }
  }

  // 删除了娱乐与积分数据：记着的等级归零，不等下次取等级。
  Future<void> forgetLevel() => memory.saveLevel(subject, 0);

  Future<void> _refreshLevel() async {
    final source = level;
    if (source == null || _accountId() == null || !_levelsOn()) return;
    final subject = this.subject;
    try {
      final current = await source();
      if (current == null || subject != this.subject) return;
      await memory.saveLevel(subject, current);
      campusLog('[Rollouts] action=level level=$current');
    } catch (error, stack) {
      campusLog('[Rollouts] action=level errorType=${error.runtimeType}\n$stack');
    }
  }
}
