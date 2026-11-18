import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/app_health.dart';
import 'package:superxd/application/network_preference.dart';
import 'package:superxd/application/app_moments.dart';
import 'package:superxd/application/app_updates.dart';
import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/application/campus_widgets.dart';
import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/application/festivals.dart';
import 'package:superxd/application/rollouts.dart';
import 'package:superxd/application/unlocks.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/course_widget.dart';
import 'package:superxd/domain/network_policy.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/local/legal_notice_memory.dart';
import 'package:superxd/page/legal_page.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/theme/campus_palette.dart';

// 组合根的生命周期钩子（[人工决策-2026-11-16 17:26:21] 组合根改应用模块加生命周期钩子，用户选定架构推荐方案）：同意协议与政策之后、
// 回到前台（resume）、每次前台可见（show）三个时机在这里统一接，各功能只登记要做什么，不再各自建 AppLifecycleListener、各自记有没有同意。
// 会联网的钩子写明属于哪一项联网服务，联网策略不允许时不做（domain/network_policy.dart）。一个钩子出错只记日志，不影响别的钩子。
class AppHooks {
  AppHooks({required Future<void> agreed, this.policy = const OnlineNetworkPolicy()}) {
    AppLifecycleListener(onResume: () => _fire(_resume), onShow: () => _fire(_show), onHide: () => _fire(_hide));
    unawaited(agreed.then((_) {
      _agreed = true;
      for (final hook in _once) {
        _runOnce(hook);
      }
      _once.clear();
    }));
    // 联网策略会变（联网偏好）：变了就把之前被挡下的一次性钩子补做（11-17 审查发现仅本机启动、改回联网后私信与账号核对要重启才恢复）。
    if (policy case final Listenable changes) changes.addListener(_retryBlocked);
  }
  final NetworkPolicy policy;
  bool _agreed = false;
  final _once = <_Hook>[], _resume = <_Hook>[], _show = <_Hook>[], _hide = <_Hook>[];
  // 同意之后该做一次、但当时联网策略不允许的钩子：策略放行时补做一次（不丢）。
  final _blocked = <_Hook>[];

  bool get agreed => _agreed;

  // 同意之后做一次（已经同意过的马上做）。
  void afterAgreed(String module, FutureOr<void> Function() action, {NetworkService? service}) {
    final hook = _Hook(module, action, service, agreedOnly: true);
    _agreed ? _runOnce(hook) : _once.add(hook);
  }

  // 每次回到前台做；agreedOnly 为真（默认）时同意之前不做。
  void onResume(String module, FutureOr<void> Function() action, {NetworkService? service, bool agreedOnly = true}) => _resume.add(_Hook(module, action, service, agreedOnly: agreedOnly));

  // 每次前台可见做（含从快捷入口、通知拉起）；agreedOnly 同上。
  void onShow(String module, FutureOr<void> Function() action, {NetworkService? service, bool agreedOnly = true}) => _show.add(_Hook(module, action, service, agreedOnly: agreedOnly));

  // 每次切到后台（不再可见）做，只给写本机的收尾用（11-17 加，健康回报把内存里的帧数写盘）；agreedOnly 同上。
  void onHide(String module, FutureOr<void> Function() action, {bool agreedOnly = true}) => _hide.add(_Hook(module, action, null, agreedOnly: agreedOnly));

  void _fire(List<_Hook> hooks) {
    for (final hook in hooks) {
      if (!hook.agreedOnly || _agreed) _run(hook);
    }
  }

  bool _allowed(_Hook hook) => hook.service == null || policy.allows(hook.service!);

  void _runOnce(_Hook hook) => _allowed(hook) ? _run(hook) : _blocked.add(hook);

  void _retryBlocked() {
    final ready = [for (final hook in _blocked) if (_allowed(hook)) hook];
    _blocked.removeWhere(ready.contains);
    ready.forEach(_run);
  }

  void _run(_Hook hook) {
    if (!_allowed(hook)) return;
    void report(Object error, StackTrace stack) => campusLog('[${hook.module}] action=hook errorType=${error.runtimeType}\n$stack');
    try {
      final result = hook.action();
      if (result is Future<void>) unawaited(result.catchError(report));
    } catch (error, stack) {
      report(error, stack);
    }
  }
}

class _Hook {
  const _Hook(this.module, this.action, this.service, {required this.agreedOnly});
  final String module;
  final FutureOr<void> Function() action;
  final NetworkService? service;
  final bool agreedOnly;
}

// 同意协议与政策之后才开始问解锁（之前只按本机配置判定公开与下架），之后每次回到前台再看一眼（距上次不到一小时不联网）。
void watchUnlocks(Unlocks unlocks, AppHooks hooks) {
  hooks.afterAgreed('Unlocks', unlocks.start, service: NetworkService.unlock);
  hooks.onResume('Unlocks', unlocks.foreground, service: NetworkService.unlock);
}

// 同意协议与政策之后拉一次灰度配置，之后每次回到前台再看一眼（距上次不到一小时不联网）；请求不带任何标识。
// 分批更新的健康回报（人工决策见 domain/app_health.dart）：启动与回到前台记今天打开过（只写本机，同意之前也记）；同意之后、回到前台时补发前几天的（联网策略 appHealth 允许才发）。
// 慢帧档（11-17 加）：引擎每交来一批帧耗时，按屏幕刷新率算一帧的预算，构建或栅格超出的算慢帧（同开发者模式的卡顿统计），只在内存里累加，切到后台时写盘。
void watchAppHealth(AppHealth health, AppHooks hooks) {
  unawaited(health.markActive());
  SchedulerBinding.instance.addTimingsCallback((timings) {
    final rate = WidgetsBinding.instance.platformDispatcher.views.firstOrNull?.display.refreshRate ?? 60;
    final budget = Duration(microseconds: (1000000 / (rate > 0 ? rate : 60)).round());
    health.countFrames(timings.length, timings.where((timing) => timing.buildDuration > budget || timing.rasterDuration > budget).length);
  });
  hooks.onHide('AppHealthFrames', health.flushFrames, agreedOnly: false);
  hooks.onResume('AppHealth', health.markActive, agreedOnly: false);
  hooks.afterAgreed('AppHealth', health.reportDue, service: NetworkService.appHealth);
  hooks.onResume('AppHealthReport', health.reportDue, service: NetworkService.appHealth);
}

void watchRollouts(Rollouts rollouts, AppHooks hooks) {
  hooks.afterAgreed('Rollouts', rollouts.refresh, service: NetworkService.rollout);
  hooks.onResume('Rollouts', rollouts.refresh, service: NetworkService.rollout);
}

// 应用更新：启动先清掉装好后的旧安装包，用户同意协议与政策、首屏稳下来后再自动检查（每个校园日一次，查到由账号应用弹窗）；
// 回到前台时接着做被搁下的安装（去开启了授权，或下载在后台完成；只动本机已下好的包，同意之前也做）。三者都自己兜住异常，只记日志。
void watchAppUpdates(AppUpdates updates, AppHooks hooks) {
  unawaited(updates.prune());
  hooks.onResume('AppUpdates', updates.resume, agreedOnly: false);
  hooks.afterAgreed('AppUpdates', () => Future<void>.delayed(appUpdateAutoCheckDelay, updates.autoCheck), service: NetworkService.appUpdate);
}

// 私信跟着当前应用账号（人工决策见 social/social_service.dart）：同意协议与政策之后，等应用账号读好本机记录就切过去，之后应用账号一变就跟着切；没配中转时为不可用。
// 仅本机时停下、联网时接着用（人工决策见 domain/network_policy.dart 的 11-16 22:24:59 那条：保留登录、只是不联网）；同意之前只记下。
void watchSocial(SocialService social, AppAccounts? appAccounts, AppHooks hooks, {NetworkPreference? network}) {
  if (network != null) {
    unawaited(social.setOffline(!network.online));
    network.addListener(() => unawaited(social.setOffline(!network.online)));
  }
  // 不挂联网策略：仅本机时 SocialService 自己停着（setOffline，不联网、状态 offline），切到账号照样要做，消息页才写得出仅本机卡。
  hooks.afterAgreed('Social', () {
    if (appAccounts == null) return social.switchAccount(null);
    void follow() {
      if (appAccounts.loaded) unawaited(social.switchAccount(appAccounts.current));
    }
    appAccounts.addListener(follow);
    follow();
  });
}

// 应用账号与教务各管各的（人工决策见 domain/app_account.dart 的 11-15 16:40:33 那条，取代 11-13「跟着教务走」：退出教务不再连带退出应用账号）。
// 启动时读本机记录；同意协议与政策之后、每次回到前台看一眼账号（隔一天才联网，没登录不联网）。
void watchAppAccounts(AppAccounts appAccounts, AppHooks hooks) {
  final loaded = appAccounts.load();
  var ready = false;
  hooks.afterAgreed('AppAccounts', () async {
    await loaded;
    ready = true;
    await appAccounts.check();
  }, service: NetworkService.appAccount);
  hooks.onResume('AppAccounts', () {
    if (ready) return appAccounts.check();
  }, service: NetworkService.appAccount);
}

// 开发者的话、节日与打扰时机：同意协议与政策之后拉一次信、补抽上次没抽成的签，之后每次回到前台、登录了（换了）应用账号再看一眼
// （信距上次不到一小时不联网；没有播过动画还没抽的节日、没登录应用账号时节日不联网）；启动与回到前台记今天打开过（活跃天数只在本机）；回到前台重新计这一次前台。
void watchMoments(AppMoments moments, AppHooks hooks, {DeveloperNotes? notes, Festivals? festivals, AppAccounts? appAccounts}) {
  unawaited(festivals?.recordActive());
  hooks.afterAgreed('Festivals', () {
    var signedIn = appAccounts?.current;
    appAccounts?.addListener(() {
      final current = appAccounts.current;
      if (current != null && current != signedIn) unawaited(festivals?.refresh());
      signedIn = current;
    });
    return festivals?.refresh();
  }, service: NetworkService.festival);
  hooks.afterAgreed('DeveloperNotes', () => notes?.autoRefresh(), service: NetworkService.developerNotes);
  hooks.onShow('AppMoments', () {
    moments.foreground();
    return festivals?.recordActive();
  }, agreedOnly: false);
  hooks.onShow('DeveloperNotes', () => notes?.autoRefresh(), service: NetworkService.developerNotes);
  hooks.onShow('Festivals', () => festivals?.refresh(), service: NetworkService.festival);
}

// 协议与政策的同意与更新提示：会话恢复之后再核对（没同意过的先征得同意，同意过的有实质变化时提示一次）。
// 恢复会换账号代次、下一帧整个账号应用重建，所以先等这一帧过去，不等就弹在要被拆掉的旧应用上、跟着消失。
Future<void> checkLegalNotice(LegalNoticeMemory legal) async {
  await WidgetsBinding.instance.endOfFrame;
  legal.check(legalRevision);
}

// 课前提醒与桌面小组件的对账时机：启动恢复会话后、回到前台、切换账号或退出登录、本机课表相关写入后；1秒防抖合并连续写入。
// 两者都只读本地数据，失败只记日志，不影响应用。
void watchLocalSchedule(AppSession session, AppHooks hooks, {required CampusReminders reminders, required CampusWidgets widgets}) {
  Timer? pending;
  void schedule() {
    pending?.cancel();
    pending = Timer(const Duration(seconds: 1), () {
      reminders.reconcile().then<void>((_) {}).catchError((Object error, StackTrace stack) {
        campusLog('[Reminder] action=reconcile errorType=${error.runtimeType}\n$stack');
      });
      widgets.refresh(signedIn: session.loggedIn).catchError((Object error, StackTrace stack) {
        campusLog('[Widget] action=refresh errorType=${error.runtimeType}\n$stack');
      });
    });
  }

  var generation = session.generation, loggedIn = session.loggedIn;
  session.addListener(() {
    if (session.generation == generation && session.loggedIn == loggedIn) return;
    generation = session.generation;
    loggedIn = session.loggedIn;
    schedule();
  });
  session.gateway.scheduleChanges.addListener(schedule);
  hooks.onResume('Reminder', schedule, agreedOnly: false);
  schedule();
}

// 小组件衬底不透明度：叠在任意桌面壁纸上，正文与次要文字仍不低于 4.5:1（见 home_widget_test）。
const widgetBackgroundAlpha = .92;

// 小组件配色取当前配色方案的卡片底色与文字色，浅色深色各一套，深浅色跟随“界面”设置。
WidgetTheme widgetThemeOf(DisplaySettings display) {
  WidgetPalette colors(Brightness brightness) {
    final palette = CampusPalette.byId(display.paletteId, brightness: brightness);
    return WidgetPalette(background: palette.surface.withValues(alpha: widgetBackgroundAlpha).toARGB32(), text: palette.onSurface.toARGB32(), secondary: palette.onSurfaceVariant.toARGB32());
  }
  return WidgetTheme(light: colors(Brightness.light), dark: colors(Brightness.dark), mode: display.themeMode.name);
}

// 只在配色或深浅色变化时重发，字号、字体、壁纸等变化不影响小组件。
void watchWidgetTheme(DisplaySettings display, CourseWidgetPort port) {
  String? applied;
  void apply() {
    final signature = '${display.paletteId}|${display.themeMode.name}';
    if (signature == applied) return;
    applied = signature;
    port.applyTheme(widgetThemeOf(display)).catchError((Object error, StackTrace stack) {
      campusLog('[Widget] action=theme errorType=${error.runtimeType}\n$stack');
    });
  }

  display.addListener(apply);
  apply();
}
