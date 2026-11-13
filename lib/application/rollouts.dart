import 'package:flutter/foundation.dart';

import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/rollout.dart';

// 灰度的编排 Rollouts（设备级，人工决策见 domain/rollout.dart）：用本机存着的配置在本机判定；配置在同意协议与政策之后、回到前台时拉，
// 两次至少隔 refreshGap，失败照旧用上次的。分桶的主体是当前教务账号对应的应用账号号，没登录用本机随机编号（不上传）。
class Rollouts extends ChangeNotifier {
  Rollouts({required this.memory, required this.channel, required this._accountId, this.feed, DateTime Function()? now}) : _now = now ?? DateTime.now;
  final RolloutMemory memory;
  // 构建渠道（如 alpha），分批更新的开关名带上它。
  final String channel;
  // 没配中转时为空：只用本机存着的配置（一般是空的），开关都按各自的默认值。
  final RolloutFeed? feed;
  final String? Function() _accountId;
  final DateTime Function() _now;

  static const refreshGap = Duration(hours: 1);
  bool _fetching = false;

  String get subject => _accountId() ?? memory.installId;

  // 功能开关：配置里有就按放量判定，没有用调用方给的默认值（新功能默认关、要关停的老功能默认开）。
  bool enabled(String id, {required bool fallback}) {
    final rule = memory.config.rules[id];
    return rule == null ? fallback : rolloutIncludes(id, subject, rule.percentAt(_now()));
  }

  // 分批更新：配置里同名开关覆盖清单的放量表（暂停、直接全量、整版关停）；清单没写放量表又没覆盖时就是全量。
  bool inUpdateBatch(AppRelease release) {
    final id = appUpdateRolloutId(channel, release.versionCode);
    final rule = memory.config.rules[id] ?? (release.rollout.isEmpty ? null : RolloutRule(id: id, stages: release.rollout));
    return rule == null || rolloutIncludes(id, subject, rule.percentAt(_now()));
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
  }
}
