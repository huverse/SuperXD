import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:superxd/device/diagnostic_device.dart';
import 'package:superxd/device/relay_release_feed.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/local/developer_settings.dart';
import 'package:superxd/local/diagnostic_log.dart';

// [人工决策-2026-10-21 23:04:08] 开发者模式（用户四项选定）：日志写进应用专属外部目录、连电脑 adb pull，另可一键导出 zip 到 Download/SuperXD；
// 开着时凡是有利于排查与优化的都记（现有日志、启动环境、页面切换、前后台、每个对外请求的接口路径状态耗时与字节数、卡顿与内存），
// 仍不记密码、Cookie、链接、查询串、请求与响应内容和实名信息；平时也在本机留约 1MB 的错误记录；隐私政策连同快递段落一起改、提示一次。
// 未选「只放私有目录」「上传到自建中转」「基础记录」「只在开启后记录」「只改文字不提示」。

// 运行环境：版本、构建号、渠道、系统、机型与处理器架构；读不到的项不写，不挡启动。
Future<Map<String, String>> appEnvironment() async {
  final environment = <String, String>{};
  try {
    final package = await PackageInfo.fromPlatform();
    environment.addAll({'version': package.version, 'build': package.buildNumber, 'flavor': appFlavor ?? '-'});
    environment.addAll(await readDeviceEnvironment());
  } catch (error, stack) {
    campusLog('[Diagnostics] action=environment errorType=${error.runtimeType}\n$stack');
  }
  environment['abi'] = appAbiName(Abi.current()) ?? Abi.current().toString();
  return environment;
}

// 开发者模式接线：按设置切换诊断记录与卡顿统计；开着时记启动环境与前后台；切到后台时把缓冲的日志写盘（平时的错误记录也靠它及时落盘）。
void watchDeveloperMode(DeveloperSettings developer, DiagnosticLog logs, {required Future<Map<String, String>> environment}) {
  final frames = _FrameWatch();
  bool? enabled;
  void apply() {
    if (developer.enabled == enabled) return;
    final started = enabled == null;
    enabled = developer.enabled;
    campusDiagnostics = developer.enabled;
    logs.developer = developer.enabled;
    developer.enabled ? frames.start() : frames.stop();
    if (!started) campusLog('[App] action=diagnostics state=${developer.enabled ? 'on' : 'off'} ${_line(logs.environment)}');
  }

  developer.addListener(apply);
  apply();
  unawaited(environment.then((value) {
    logs.environment = value;
    if (campusDiagnostics) campusLog('[App] action=start ${_line(value)}');
  }));
  AppLifecycleListener(onStateChange: (state) {
    if (campusDiagnostics) campusLog('[App] action=lifecycle state=${state.name} rssMb=${_rssMb()}');
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused || state == AppLifecycleState.detached) unawaited(logs.flush());
  });
}

// 页面切换：路由位置变了才记一条，只记路径（路由里只有 /legal/:kind 与工具 id 两种参数，都不带个人信息）。返回解除监听的函数。
VoidCallback watchRoutes(GoRouter router) {
  String? last;
  void listener() {
    if (!campusDiagnostics) return;
    final path = router.routerDelegate.currentConfiguration.uri.path;
    if (path == last) return;
    last = path;
    campusLog('[Route] action=change path=$path');
  }

  router.routerDelegate.addListener(listener);
  return () => router.routerDelegate.removeListener(listener);
}

String _line(Map<String, String> environment) => [for (final MapEntry(:key, :value) in environment.entries) '$key=${value.replaceAll(' ', '_')}'].join(' ');

int _rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);

// 卡顿与内存：每 10 秒汇总一次，窗口里有构建或栅格超出一帧预算的才记一条（帧数、慢帧数、最慢的两项耗时、内存），不逐帧刷日志。
class _FrameWatch {
  var _frames = 0, _slow = 0;
  var _build = Duration.zero, _raster = Duration.zero;
  DateTime? _since;
  // 只在真开着时注销：启动时开发者模式关着也会走 stop，注销没注册过的回调在调试包里断言失败、main 后面都不执行。
  var _running = false;

  void start() {
    if (_running) return;
    _running = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void stop() {
    if (!_running) return;
    _running = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _reset(null);
  }

  void _reset(DateTime? since) {
    _frames = 0;
    _slow = 0;
    _build = Duration.zero;
    _raster = Duration.zero;
    _since = since;
  }

  void _onTimings(List<FrameTiming> timings) {
    final rate = WidgetsBinding.instance.platformDispatcher.views.firstOrNull?.display.refreshRate ?? 60;
    final budget = Duration(microseconds: (1000000 / (rate > 0 ? rate : 60)).round());
    for (final timing in timings) {
      _frames++;
      if (timing.buildDuration > budget || timing.rasterDuration > budget) _slow++;
      if (timing.buildDuration > _build) _build = timing.buildDuration;
      if (timing.rasterDuration > _raster) _raster = timing.rasterDuration;
    }
    final now = DateTime.now(), since = _since ??= now;
    final window = now.difference(since);
    if (window < const Duration(seconds: 10)) return;
    if (_slow > 0) {
      campusLog('[Frame] action=summary seconds=${window.inSeconds} frames=$_frames slow=$_slow worstBuildMs=${_build.inMilliseconds} worstRasterMs=${_raster.inMilliseconds} budgetMs=${(budget.inMicroseconds / 1000).toStringAsFixed(1)} rssMb=${_rssMb()}');
    }
    _reset(now);
  }
}
