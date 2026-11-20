import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/domain/rollout.dart';

// 灰度的编排 Rollouts（设备级，人工决策见 domain/rollout.dart）：用本机存着的配置在本机判定；配置在同意协议与政策之后、回到前台时拉，
// 两次至少隔 refreshGap，失败照旧用上次的。分桶的主体是当前应用账号的账号号，没登录用本机随机编号（不上传）。
// 登录着应用账号时同一时机取一次积分等级（level，经挑战与积分的签名请求），按等级加权；只因等级才进的批次记在本机，降级也不踢出。
// levelsOn 为假（联网偏好是仅本机，人工决策见 domain/network_policy.dart）时不取等级、按 Lv0 判定，已经因等级进了的批次照旧算。
// 11-16 起（人工决策见 domain/rollout.dart 文件头 11-16 那条）：开关的条件（时间窗、平台、渠道、版本号、等级）都满足才按比例判定；
// 登录着应用账号时同一时机问一次点名（targets，顺带账号建立的时刻，判 minAccountDays），点名的开关不看比例与条件、只看到期时刻，问到的记在本机（换账号从头记）。
// 11-20 起改了立即生效（人工决策见 domain/rollout.dart 的 RolloutSignals）：回到前台时配置与点名都带上次的版本号核对（没变中转回 304），两次至少隔 checkGap；
// 中转回复头里的版本号和本机记的不一样就马上重新取（signals，同一个版本号一次运行只触发一次）；积分等级照旧至少隔 refreshGap 才取。
class Rollouts extends ChangeNotifier implements FeatureGate {
  Rollouts({required this.memory, required this.channel, required this.platform, required this.versionCode, required this._accountId, this.feed, this.level, this.targets, RolloutSignals? signals, bool Function()? levelsOn, DateTime Function()? now})
    : _levelsOn = levelsOn ?? (() => true),
      _now = now ?? DateTime.now {
    addListener(() => _changes.add(null));
    _signals = signals?.stream.listen(_observe);
  }
  final RolloutMemory memory;
  // 构建渠道（如 alpha），分批更新的开关名带上它，开关的 channels 条件也按它。
  final String channel;
  // 平台（android、ios）与安装的版本号（构建号），开关的 platforms 与版本区间条件按它们。
  final String platform;
  final int versionCode;
  // 当前应用账号被点名了哪些（etag 是上次的版本号，为空问全量）；没登录、没配中转时为空（照旧用本机记着的）。
  final Future<RolloutTargetsFetch?> Function(String? etag)? targets;
  // 没配中转时为空：只用本机存着的配置（一般是空的），开关都按各自的默认值。
  final RolloutFeed? feed;
  // 当前应用账号的积分等级；没登录或这次取不到为空（照旧用本机记着的）。没配中转时整个为空。
  final Future<int?> Function()? level;
  final String? Function() _accountId;
  final bool Function() _levelsOn;
  final DateTime Function() _now;

  // 积分等级至少隔这么久取一次；配置与点名回到前台就核对，至少隔 checkGap（连着切前后台不重复问）。
  static const refreshGap = Duration(hours: 1);
  static const checkGap = Duration(seconds: 30);
  bool _fetching = false, _asking = false, _started = false;
  DateTime? _checkedAt, _levelAt;
  // 这次运行里已经为之重新取过的版本号：同一个不再触发（中转几个实例算得不同步时也不来回）。
  final _seenConfig = <String>{}, _seenTargets = <String>{};
  StreamSubscription<RolloutSignal>? _signals;
  final _changes = StreamController<void>.broadcast();

  // 配置、点名或等级变了发一次（同 notifyListeners），给百宝箱这类不依赖本层的页面用。
  @override
  Stream<void> get changes => _changes.stream;

  String get subject => _accountId() ?? memory.installId;

  // 本机存着的配置（解锁的清单也在里面，见 application/unlocks.dart）；拉到新配置时 notifyListeners。
  RolloutConfig get config => memory.config;

  // 功能开关：被点名（没到期）的直接开；配置里有就看条件、再按放量判定，没有用调用方给的默认值（新功能默认关、要关停的老功能默认开）。
  bool enabled(String id, {required bool fallback}) {
    final now = _now();
    if (memory.targetsOf(subject).any((target) => target.id == id && target.activeAt(now))) return true;
    final rule = memory.config.rules[id];
    if (rule == null) return fallback;
    final created = memory.accountCreatedOf(subject);
    final accountDays = created == null ? null : now.difference(created).inDays;
    if (!rule.applies(now: now, platform: platform, channel: channel, versionCode: versionCode, level: _levelsOn() ? memory.levelOf(subject) : 0, accountDays: accountDays)) return false;
    return _includes(id, rule.percentAt(now));
  }

  // 登记过的功能开关（domain/feature_flags.dart）：功能只经它们问。
  @override
  bool isOn(FeatureFlag flag) => enabled(flag.id, fallback: flag.fallback);

  // 开着时配置给这个开关的参数；没开、没写这一项为空（点名开的也读配置里的参数）。
  Object? param(FeatureFlag flag, String key) => isOn(flag) ? memory.config.rules[flag.id]?.params[key] : null;

  // 分批更新：配置里同名开关覆盖清单的放量表（暂停、直接全量、整版关停）；清单没写放量表又没覆盖时就是全量。
  bool inUpdateBatch(AppRelease release) {
    final id = appUpdateRolloutId(channel, release.versionCode);
    // 健康回报自动暂停了这一版：只少提示（人工决策见 domain/app_health.dart）。
    if (memory.config.paused.contains(id)) return false;
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

  // 同意协议与政策后、回到前台时由组合根调：配置与点名带版本号核对，等级隔 refreshGap 取一次。
  Future<void> refresh() async {
    _started = true;
    final now = _now(), checkedAt = _checkedAt;
    if (feed == null || (checkedAt != null && now.difference(checkedAt) < checkGap)) return;
    _checkedAt = now;
    await _refreshConfig();
    final levelAt = _levelAt;
    if (levelAt == null || now.difference(levelAt) >= refreshGap) {
      _levelAt = now;
      await _refreshLevel();
    }
    await _refreshTargets(conditional: true);
  }

  // 回复头里的版本号：和本机记的不一样、这次运行还没为它取过，就马上重新取（同意协议与政策、第一次 refresh 之前不动）。
  void _observe(RolloutSignal signal) {
    if (!_started) return;
    if (signal.config case final config? when config != memory.etag && _seenConfig.add(config)) {
      campusLog('[Rollouts] action=signal part=config');
      unawaited(_refreshConfig());
    }
    if (signal.targets case final targets? when _accountId() != null && targets != memory.targetsEtagOf(subject) && _seenTargets.add(targets)) {
      campusLog('[Rollouts] action=signal part=targets');
      unawaited(_refreshTargets(conditional: false));
    }
  }

  // 取配置：带上次的版本号，没变只记一下时刻；失败照旧用上次的。同一时刻只取一次。
  Future<void> _refreshConfig() async {
    final source = feed;
    if (source == null || _fetching) return;
    _fetching = true;
    try {
      final fetched = await source.fetch(etag: memory.etag);
      final config = fetched.config;
      if (config == null) {
        campusLog('[Rollouts] action=refresh unchanged=true');
        return;
      }
      await memory.save(config, _now(), etag: fetched.etag);
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

  // 问一次点名：conditional 为真时带上次的版本号（没变什么都不做）；没登录或这次问不到时照旧用记着的；问到了（含空列表，即全撤销了）就记下，变了通知。
  // 回复头触发的问全量：头里的版本号是那台设备的（私信设备与应用账号的密钥各记一份），拿它当条件可能对不上，问一次全量最稳。
  Future<void> _refreshTargets({required bool conditional}) async {
    final source = targets;
    if (source == null || _accountId() == null || _asking) return;
    final subject = this.subject;
    _asking = true;
    try {
      final reply = await source(conditional ? memory.targetsEtagOf(subject) : null);
      final current = reply?.targets;
      if (reply == null || current == null || subject != this.subject) return;
      String signature(Iterable<RolloutTarget> flags, DateTime? created) => '${flags.map((target) => '${target.id}@${target.until}').join(',')}|$created';
      final before = signature(memory.targetsOf(subject), memory.accountCreatedOf(subject));
      await memory.saveTargets(subject, current, etag: reply.etag);
      campusLog('[Rollouts] action=targets count=${current.flags.length}');
      if (signature(current.flags, current.accountCreatedAt) != before) notifyListeners();
    } on RolloutException catch (error) {
      campusLog('[Rollouts] action=targets errorType=RolloutException message=${error.message}');
    } catch (error, stack) {
      campusLog('[Rollouts] action=targets errorType=${error.runtimeType}\n$stack');
    } finally {
      _asking = false;
    }
  }

  @override
  void dispose() {
    unawaited(_signals?.cancel());
    super.dispose();
  }

  // 删除了游乐场与积分的数据：记着的等级归零，不等下次取等级。
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
