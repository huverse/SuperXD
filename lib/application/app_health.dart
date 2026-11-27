import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/app_health.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';

// 分批更新的健康回报与意见的编排 AppHealth（设备级，人工决策见 domain/app_health.dart）：
// - markActive：启动与回到前台记今天打开过、装着哪个版本（换了版本记下第一次打开的那天，意见窗口从那天算）；只写本机。
// - 每个校园日每个用过的版本一项（11-27 的 [人工决策] 见 domain/app_health.dart）：换版本不动当天旧版本那一项，各报各的。
// - markFatal：这一版运行中没接住的异常、框架报错，把那天这个版本记成有致命错误；markExit：系统记下的上次崩溃与无响应，
//   按出错时刻认那天在用的版本（可能是升级前的旧版本）。组合根接上错误出口与上次退出原因。
// - reportDue：同意协议与政策后、回到前台时由组合根调（联网策略 appHealth 允许才调）：发前一天及以前没发过的，最多 healthReportBatch 份；
//   连不上的留着下次，服务器拒收的记成发过；同一时刻只发一轮。
// - sendFeedback：关于页「新版本反馈」提交，成功后这个版本不再出现入口。没配中转时 client 为空，什么都不发、也不给入口。
// - markLaunch、countFrames、flushFrames：性能档位的本机原始数（11-17 的 [人工决策] 见 domain/app_health.dart）：组合根在首帧上屏时记一次启动用时，
//   引擎交来的帧耗时按批累加在内存里（不逐批写盘），切到后台与跨过校园日界时写进那一天的记录。
class AppHealth extends ChangeNotifier {
  AppHealth({required this._memory, required this.channel, required this.platform, required this.versionCode, this._client, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final AppHealthMemory _memory;
  final AppHealthClient? _client;
  final String channel;
  final String platform;
  final int versionCode;
  final DateTime Function() _clock;
  Future<void>? _reporting;

  String _dayOf(DateTime at) => formatCampusDate(campusInstant(at.toUtc()));
  String get _today => _dayOf(_clock());

  bool get feedbackOpen => _client != null && healthFeedbackOpen(_memory.record, versionCode, _today);

  bool _mine(HealthDay item, String day) => item.day == day && item.versionCode == versionCode;

  Future<void> markActive() async {
    final record = _memory.record, today = _today;
    final days = healthRecent(record.days, today);
    final known = days.any((day) => _mine(day, today));
    final sameVersion = record.versionCode == versionCode;
    if (known && sameVersion) return;
    await _save(HealthRecord(
      days: known ? days : healthRecent([...days, HealthDay(day: today, versionCode: versionCode, since: _clock().toUtc())], today),
      versionCode: versionCode,
      versionSince: sameVersion ? record.versionSince : today,
      feedbackSent: sameVersion && record.feedbackSent,
    ));
  }

  // 这一版运行中出的错：at 是出错的时刻，记到那天这个版本那一项，没记过打开就补一项。
  Future<void> markFatal(DateTime at) => _markFatal(at, exited: false);

  // 上次的进程异常结束：at 是系统记下的时刻，记到那天那时在用的那一项（healthDayAt）；那天没有记录才补一项给现在装着的版本。
  Future<void> markExit(DateTime at) => _markFatal(at, exited: true);

  Future<void> _markFatal(DateTime at, {required bool exited}) async {
    final record = _memory.record, day = _dayOf(at), today = _today;
    if (day.compareTo(today) > 0) return;
    final days = healthRecent(record.days, today);
    final target = exited ? healthDayAt(days, day, at) : days.where((item) => _mine(item, day)).firstOrNull;
    if (target?.fatal == true) return;
    await _save(HealthRecord(
      days: target == null
          ? healthRecent([...days, HealthDay(day: day, versionCode: versionCode, fatal: true, since: at.toUtc())], today)
          : [for (final item in days) identical(item, target) ? item.copyWith(fatal: true) : item],
      versionCode: record.versionCode,
      versionSince: record.versionSince,
      feedbackSent: record.feedbackSent,
    ));
  }

  // 记一次启动（Dart 入口到首帧上屏），记到今天这个版本那一项（没有就补一项，同一天别的版本那项不动）。
  Future<void> markLaunch(Duration elapsed) {
    final record = _memory.record, today = _today;
    final days = healthRecent(record.days, today);
    final current = days.where((day) => _mine(day, today)).firstOrNull ?? HealthDay(day: today, versionCode: versionCode, since: _clock().toUtc());
    return _save(HealthRecord(
      days: healthRecent([...days.where((item) => !_mine(item, today)), current.withLaunch(elapsed)], today),
      versionCode: record.versionCode,
      versionSince: record.versionSince,
      feedbackSent: record.feedbackSent,
    ));
  }

  String? _framesDay;
  DateTime? _framesSince;
  var _frames = 0, _slowFrames = 0;

  // 一批帧：只在内存里加；跨过校园日界时先把前一天的写进记录。
  void countFrames(int frames, int slow) {
    final today = _today;
    if (_framesDay != today) {
      unawaited(flushFrames());
      _framesSince = _clock().toUtc();
    }
    _framesDay = today;
    _frames += frames;
    _slowFrames += slow;
  }

  Future<void> flushFrames() async {
    final day = _framesDay, since = _framesSince, frames = _frames, slow = _slowFrames;
    _frames = 0;
    _slowFrames = 0;
    if (day == null || frames == 0) return;
    final record = _memory.record, today = _today;
    var days = healthRecent(record.days, today);
    if (!days.any((item) => _mine(item, day))) days = healthRecent([...days, HealthDay(day: day, versionCode: versionCode, since: since)], today);
    await _save(HealthRecord(
      days: [for (final item in days) _mine(item, day) ? item.copyWith(frames: item.frames + frames, slowFrames: item.slowFrames + slow) : item],
      versionCode: record.versionCode,
      versionSince: record.versionSince,
      feedbackSent: record.feedbackSent,
    ));
  }

  Future<void> reportDue() => _reporting ??= _report().whenComplete(() => _reporting = null);

  Future<void> _report() async {
    final client = _client;
    if (client == null) return;
    for (final day in healthDue(_memory.record, _today)) {
      try {
        await client.report(channel: channel, platform: platform, day: day);
      } on AppHealthException catch (error) {
        campusLog('[AppHealth] action=report day=${day.day} errorType=AppHealthException message=${error.message} rejected=${error.rejected}');
        if (!error.rejected) return;
      }
      final record = _memory.record;
      await _save(HealthRecord(
        days: [for (final item in record.days) item.day == day.day && item.versionCode == day.versionCode ? item.copyWith(reported: true) : item],
        versionCode: record.versionCode,
        versionSince: record.versionSince,
        feedbackSent: record.feedbackSent,
      ));
      campusLog('[AppHealth] action=reported day=${day.day} versionCode=${day.versionCode} fatal=${day.fatal} launch=${day.launchTier} frames=${day.frameTier}');
    }
  }

  // 提交意见；失败抛 AppHealthException（message 给页面显示）。
  Future<void> sendFeedback({required bool good, required String text}) async {
    final client = _client;
    if (client == null) throw const AppHealthException('这个版本不能提交反馈');
    await client.feedback(channel: channel, platform: platform, versionCode: versionCode, good: good, text: text.trim());
    final record = _memory.record;
    await _save(HealthRecord(days: record.days, versionCode: record.versionCode, versionSince: record.versionSince, feedbackSent: true));
  }

  // 写本机失败只记日志：最坏是少报或多报一天。
  Future<void> _save(HealthRecord record) async {
    final saving = _memory.save(record);
    notifyListeners();
    try {
      await saving;
    } catch (error, stack) {
      campusLog('[AppHealth] action=save errorType=${error.runtimeType}\n$stack');
    }
  }
}
