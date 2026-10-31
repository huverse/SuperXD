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
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/text_size_range.dart';

// [人工决策-2026-10-21 23:04:08] 开发者模式（用户四项选定）：日志写进应用专属外部目录、连电脑 adb pull，另可一键导出 zip 到 Download/SuperXD；
// 开着时凡是有利于排查与优化的都记（现有日志、启动环境、页面切换、前后台、每个对外请求的接口路径状态耗时与字节数、卡顿与内存），
// 仍不记密码、Cookie、链接、查询串、请求与响应内容和实名信息；平时也在本机留约 1MB 的错误记录；隐私政策连同快递段落一起改、提示一次。
// 未选「只放私有目录」「上传到自建中转」「基础记录」「只在开启后记录」「只改文字不提示」。
// [人工决策-2026-10-21 23:48:00] 第二轮（用户参照 DoKit、vConsole、Sentry、Crashlytics、微信 xlog 选定五项）：上次退出原因（下面的 recordExitReasons）、
// 同类错误聚合与旧日志压缩（见 local/diagnostic_log.dart）、悬浮按钮打标记与复制诊断摘要（见 page/developer_page.dart）；登录页加「关于」入口。
// 未选「按启动分段与启动耗时」「网络面板」「查看日志实时跟随」。

// 上次进程为什么结束（系统记下的，Android 11 起）：每次启动读一次，只记上回读过之后的。异常结束按错误记，平时也进错误记录，无响应附系统给的线程堆栈摘要；
// 其余（自己退出、用户划掉、升级、后台被回收等）只在开发者模式下记一行。读到的最新时刻存进 marker。
// [人工决策-2026-10-22 16:24:03] 用户选定后台被回收不算错误（同 Android vitals、Crashlytics 只把崩溃与无响应当错误）：崩溃、原生崩溃、无响应、初始化失败任何时候都算；
// 内存不足、被信号杀、资源超限、依赖进程退出只在当时在前台或可见时才算，切到后台后被系统或国产系统的后台清理杀掉很常见，不是应用的问题，平时记成错误会刷满错误记录。
const _abnormalExits = {'CRASH', 'CRASH_NATIVE', 'ANR', 'INITIALIZATION_FAILURE'};
const _abnormalWhenVisible = {'SIGNALED', 'LOW_MEMORY', 'EXCESSIVE_RESOURCE_USAGE', 'DEPENDENCY_DIED'};
// 系统的进程重要度（RunningAppProcessInfo）：越小越靠前台，前台 100、前台服务 125、可见 200，再往后是用户看不见的后台与缓存。
const _visibleImportance = 200;

Future<void> recordExitReasons({required File marker, required Future<List<ProcessExit>> Function(int since) read}) async {
  try {
    final since = await marker.exists() ? int.tryParse((await marker.readAsString()).trim()) ?? 0 : 0;
    final exits = await read(since);
    if (exits.isEmpty) return;
    // 系统按新到旧给，按发生先后记。
    for (final exit in exits.reversed) {
      final abnormal = _abnormalExits.contains(exit.reason) || _abnormalWhenVisible.contains(exit.reason) && exit.importance <= _visibleImportance;
      if (!abnormal && !campusDiagnostics) continue;
      final at = DateTime.fromMillisecondsSinceEpoch(exit.timestamp, isUtc: true).toIso8601String();
      final description = exit.description.replaceAll(RegExp(r'\s+'), '_');
      final line = '$diagnosticExitHead ${abnormal ? 'errorType' : 'reason'}=${exit.reason} at=$at status=${exit.status} importance=${exit.importance} pssMb=${exit.pssKb ~/ 1024} rssMb=${exit.rssKb ~/ 1024}${description.isEmpty ? '' : ' description=$description'}';
      campusLog(exit.trace.isEmpty ? line : '$line\n${exit.trace}');
    }
    await marker.writeAsString('${exits.map((exit) => exit.timestamp).reduce((left, right) => left > right ? left : right)}', flush: true);
  } catch (error, stack) {
    campusLog('[Diagnostics] action=exit_reasons errorType=${error.runtimeType}\n$stack');
  }
}

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
// 运行环境到开发者模式第一次开着时才读、只读一次：普通用户用不到它，不在启动时为它多调系统接口（机型信息要在主线程上收集一大份）。
void watchDeveloperMode(DeveloperSettings developer, DiagnosticLog logs, {required Future<Map<String, String>> Function() environment}) {
  final frames = _FrameWatch();
  bool? enabled;
  Future<void>? reading;
  void apply() {
    if (developer.enabled == enabled) return;
    final started = enabled == null;
    enabled = developer.enabled;
    campusDiagnostics = developer.enabled;
    logs.developer = developer.enabled;
    developer.enabled ? frames.start() : frames.stop();
    if (!started) campusLog(['[App] action=diagnostics state=${developer.enabled ? 'on' : 'off'}', if (logs.environment.isNotEmpty) _line(logs.environment)].join(' '));
    if (developer.enabled) {
      reading ??= environment().then((value) {
        logs.environment = value;
        if (campusDiagnostics) campusLog('[App] action=${started ? 'start' : 'environment'} ${_line(value)}');
      });
    }
  }

  developer.addListener(apply);
  apply();
  AppLifecycleListener(onStateChange: (state) {
    if (campusDiagnostics) campusLog('[App] action=lifecycle state=${state.name} rssMb=${_rssMb()}');
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused || state == AppLifecycleState.detached) unawaited(logs.flush(settle: true));
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

// [人工决策-2026-10-31 20:01:37] 为优化字号推荐，用户选「字号状态加变化」（未选「运行环境只加静态几项」），隐私政策第八节补一句、修订号不加：
// 开发者模式开着时记一条字号状态，之后屏宽、像素密度、系统字号、粗体文本、应用字号设置、字体任一变化再记一条，带这台的推荐上限
// 与当前字号下会改排的地方（同外观页的字号条，见 page/text_size_range.dart）；当前这组也交给诊断摘要与导出的 about.txt。
// 字号条拖动中只预览、松手才保存，拖动不刷日志；分屏拖动这类连续变化停 1 秒再记最后的样子。
class TextSizeWatch extends StatefulWidget {
  const TextSizeWatch({super.key, required this.developer, required this.logs, required this.display, required this.child});
  final DeveloperSettings developer;
  final DiagnosticLog logs;
  final DisplaySettings display;
  final Widget child;

  @override
  State<TextSizeWatch> createState() => _TextSizeWatchState();
}

class _TextSizeWatchState extends State<TextSizeWatch> {
  static const _settle = Duration(seconds: 1);
  Timer? _timer;
  String? _logged;

  @override
  void initState() {
    super.initState();
    widget.developer.addListener(_developerChanged);
  }

  @override
  void dispose() {
    widget.developer.removeListener(_developerChanged);
    _timer?.cancel();
    super.dispose();
  }

  // 关掉再打开开发者模式时重新记一条。
  void _developerChanged() => setState(() => _logged = null);

  // 推荐上限的几个输入（读的同时登记依赖，变了就重建）：屏宽按逻辑像素取整，字号是标准字号的倍数。
  ({Map<String, String> inputs, double width, double effective}) _read() {
    final width = MediaQuery.sizeOf(context).width;
    final system = CampusTextScale.systemOf(context);
    final chosen = widget.display.textSize;
    final effective = DisplaySettings.effectiveTextSize(chosen, system);
    return (
      inputs: {
        'screenWidth': '${width.round()}',
        'pixelRatio': _fixed(MediaQuery.devicePixelRatioOf(context)),
        'systemTextSize': _fixed(system),
        'boldText': '${MediaQuery.boldTextOf(context)}',
        'textSize': chosen == null ? 'system' : _fixed(chosen),
        'effectiveTextSize': _fixed(effective),
        'font': widget.display.fontId,
      },
      width: width,
      effective: effective,
    );
  }

  void _record() {
    if (!mounted || !campusDiagnostics) return;
    final (:inputs, :width, :effective) = _read();
    final key = _line(inputs);
    if (key == _logged) return;
    _logged = key;
    final relayout = textSizeAdaptations(context, width, effective);
    final state = {...inputs, 'comfortableMax': _fixed(comfortableTextSize(context, width)), 'relayout': relayout.isEmpty ? 'none' : relayout.join('、')};
    widget.logs.textSize = state;
    campusLog('[TextSize] action=state ${_line(state)}');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.developer.enabled && _line(_read().inputs) != _logged) {
      _timer?.cancel();
      _timer = Timer(_settle, _record);
    }
    return widget.child;
  }
}

String _fixed(double value) => value.toStringAsFixed(2);

String _line(Map<String, String> environment) => [for (final MapEntry(:key, :value) in environment.entries) '$key=${value.replaceAll(' ', '_')}'].join(' ');

int _rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);

// 卡顿与内存：每 10 秒汇总一次，窗口里有构建或栅格超出一帧预算的才记一条（帧数、慢帧数、最慢的两项耗时、内存），不逐帧刷日志。
class _FrameWatch {
  static const _window = Duration(seconds: 10);
  var _frames = 0, _slow = 0;
  var _build = Duration.zero, _raster = Duration.zero, _budget = Duration.zero;
  DateTime? _since, _last;
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
    _reset();
    _last = null;
  }

  // 下一个窗口从下一次回报算起。
  void _reset() {
    _frames = 0;
    _slow = 0;
    _build = Duration.zero;
    _raster = Duration.zero;
    _since = null;
  }

  void _onTimings(List<FrameTiming> timings) {
    final now = DateTime.now();
    // 停过一阵没出帧（页面静止时不出帧也不回报）：上一个窗口按它最后一次回报结掉，不把空闲时长和之后别的页面的帧并进同一条。
    if (_last case final last? when now.difference(last) >= _window) _summarize(last);
    _last = now;
    final rate = WidgetsBinding.instance.platformDispatcher.views.firstOrNull?.display.refreshRate ?? 60;
    _budget = Duration(microseconds: (1000000 / (rate > 0 ? rate : 60)).round());
    for (final timing in timings) {
      _frames++;
      if (timing.buildDuration > _budget || timing.rasterDuration > _budget) _slow++;
      if (timing.buildDuration > _build) _build = timing.buildDuration;
      if (timing.rasterDuration > _raster) _raster = timing.rasterDuration;
    }
    final since = _since ??= now;
    if (now.difference(since) >= _window) _summarize(now);
  }

  void _summarize(DateTime end) {
    if (_since case final since? when _slow > 0) {
      campusLog('[Frame] action=summary seconds=${end.difference(since).inSeconds} frames=$_frames slow=$_slow worstBuildMs=${_build.inMilliseconds} worstRasterMs=${_raster.inMilliseconds} budgetMs=${(_budget.inMicroseconds / 1000).toStringAsFixed(1)} rssMb=${_rssMb()}');
    }
    _reset();
  }
}
