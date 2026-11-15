import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/rollout.dart';

// 灰度的编排 Rollouts（设备级，人工决策见 domain/rollout.dart）：用本机存着的配置在本机判定；配置在同意协议与政策之后、回到前台时拉，
// 两次至少隔 refreshGap，失败照旧用上次的。分桶的主体是当前教务账号对应的应用账号号，没登录用本机随机编号（不上传）。
// 登录着应用账号时同一时机取一次积分等级（level，经挑战与积分的签名请求），按等级加权；只因等级才进的批次记在本机，降级也不踢出。
// levelsOn 为假（娱乐与积分关着，人工决策见 domain/leisure.dart）时不取等级、按 Lv0 判定，已经因等级进了的批次照旧算。
class Rollouts extends ChangeNotifier {
  Rollouts({required this.memory, required this.channel, required this._accountId, this.feed, this.level, bool Function()? levelsOn, DateTime Function()? now})
    : _levelsOn = levelsOn ?? (() => true),
      _now = now ?? DateTime.now;
  final RolloutMemory memory;
  // 构建渠道（如 alpha），分批更新的开关名带上它。
  final String channel;
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

  // 功能开关：配置里有就按放量判定，没有用调用方给的默认值（新功能默认关、要关停的老功能默认开）。
  bool enabled(String id, {required bool fallback}) {
    final rule = memory.config.rules[id];
    return rule == null ? fallback : _includes(id, rule.percentAt(_now()));
  }

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
