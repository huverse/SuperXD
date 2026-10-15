import 'package:flutter/foundation.dart';

import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/campus_log.dart';

// 启动后等首屏与转场稳下来再自动检查。
const appUpdateAutoCheckDelay = Duration(seconds: 3);

enum AppUpdatePhase { idle, checking, upToDate, available, downloading, verifying, needsPermission, readyToInstall, failed }

// 应用内更新编排：检查（自动每个校园日一次、手动不限）→ 用户点更新才下载 → 核对 SHA-256、包名、版本号与签名证书 →
// 交给系统安装器。没有「安装未知应用」授权时引导去开启，回到前台接着装；下载在后台完成时等回前台再拉起安装界面
// （Android 10 起后台不能启动界面）。状态变化经通知交给界面原地显示。
class AppUpdates extends ChangeNotifier {
  AppUpdates({
    required this.feed,
    required this.files,
    required this.installer,
    required this.memory,
    required this.installedVersionCode,
    required this._foreground,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final AppReleaseFeed feed;
  final AppPackageFiles files;
  final AppInstaller installer;
  final AppUpdateMemory memory;
  final int installedVersionCode;
  final bool Function() _foreground;
  final DateTime Function() _clock;

  AppUpdatePhase phase = AppUpdatePhase.idle;
  AppRelease? release;
  AppUpdateUrgency urgency = AppUpdateUrgency.none;
  double progress = 0;
  String? error;
  String? _path;
  // 去开启授权、或下载在后台完成时置位：回到前台只接着装这一次，用户关掉安装界面回来不会再被拉起。
  bool _installOnResume = false;

  // 自动检查查到、等界面弹窗的版本；界面弹出时用 takePrompt 取走。
  AppRelease? _prompt;
  AppRelease? takePrompt() {
    final prompt = _prompt;
    _prompt = null;
    return prompt;
  }

  bool get _busy => phase == AppUpdatePhase.checking || phase == AppUpdatePhase.downloading || phase == AppUpdatePhase.verifying;

  // 启动时调用：不到时候（今天查过、也没有待办的必须更新）不联网；失败只记日志，不打扰用户。
  Future<void> autoCheck() async {
    if (!appUpdateCheckDue(memory.lastCheckedAt, _clock(), forcedPending: memory.forcedPending)) return;
    final found = await _check(manual: false);
    if (found != null && appUpdatePromptDue(urgency, found, memory.skippedVersionCode)) {
      _prompt = found;
      notifyListeners();
    }
  }

  // 关于页的检查更新：不受每天一次与跳过的限制，失败把原因留在 error。
  Future<void> check() => _check(manual: true);

  Future<AppRelease?> _check({required bool manual}) async {
    if (_busy) return null;
    phase = AppUpdatePhase.checking;
    error = null;
    notifyListeners();
    try {
      final latest = await feed.latest();
      release = latest;
      urgency = latest == null ? AppUpdateUrgency.none : appUpdateUrgency(installedVersionCode, latest);
      phase = urgency == AppUpdateUrgency.none ? AppUpdatePhase.upToDate : AppUpdatePhase.available;
      await memory.save(lastCheckedAt: _clock().toUtc(), skippedVersionCode: memory.skippedVersionCode, forcedPending: urgency == AppUpdateUrgency.forced);
      campusLog('[AppUpdate] action=check manual=$manual result=${phase.name} installed=$installedVersionCode latest=${latest?.versionCode}');
      return urgency == AppUpdateUrgency.none ? null : latest;
    } on AppUpdateException catch (failure, stack) {
      campusLog('[AppUpdate] action=check manual=$manual errorType=AppUpdateException\n$stack');
      phase = manual ? AppUpdatePhase.failed : AppUpdatePhase.idle;
      error = failure.message;
      return null;
    } catch (failure, stack) {
      campusLog('[AppUpdate] action=check manual=$manual errorType=${failure.runtimeType}\n$stack');
      phase = manual ? AppUpdatePhase.failed : AppUpdatePhase.idle;
      error = '检查更新没完成，请稍后再试';
      return null;
    } finally {
      notifyListeners();
    }
  }

  // 「跳过这个版本」：之后自动检查不再为它弹窗，更新的版本照常提示；强制更新不给跳过。
  Future<void> skip() async {
    final current = release;
    if (current == null || urgency != AppUpdateUrgency.optional) return;
    await memory.save(lastCheckedAt: memory.lastCheckedAt, skippedVersionCode: current.versionCode, forcedPending: memory.forcedPending);
  }

  // 下载（缓存里已有且校验通过就不再下）→ 核对 → 安装。
  Future<void> update() async {
    final current = release;
    final apk = current?.apk;
    if (current == null || apk == null || _busy) return;
    error = null;
    try {
      final path = await files.pathFor(current);
      var verified = false;
      if (await files.exists(path)) {
        _enter(AppUpdatePhase.verifying);
        verified = await files.sha256Of(path) == apk.sha256;
      }
      if (!verified) {
        progress = 0;
        _enter(AppUpdatePhase.downloading);
        await files.download(apk.url, path, onProgress: (value) {
          progress = value;
          notifyListeners();
        });
        _enter(AppUpdatePhase.verifying);
        if (await files.sha256Of(path) != apk.sha256) {
          await files.delete(path);
          throw const AppUpdateException('安装包没下完整，请重试');
        }
      }
      final identity = await installer.inspect(path);
      if (!identity.samePackage || !identity.sameSigner || identity.versionCode != current.versionCode) {
        await files.delete(path);
        campusLog('[AppUpdate] action=inspect samePackage=${identity.samePackage} sameSigner=${identity.sameSigner} versionCode=${identity.versionCode}');
        throw const AppUpdateException('安装包与本应用对不上，已删除，请到发布页下载');
      }
      _path = path;
      await _install();
    } on AppUpdateCancelled {
      campusLog('[AppUpdate] action=download result=cancelled');
      phase = AppUpdatePhase.available;
    } on AppUpdateException catch (failure, stack) {
      campusLog('[AppUpdate] action=update errorType=AppUpdateException\n$stack');
      phase = AppUpdatePhase.failed;
      error = failure.message;
    } catch (failure, stack) {
      campusLog('[AppUpdate] action=update errorType=${failure.runtimeType}\n$stack');
      phase = AppUpdatePhase.failed;
      error = '更新没完成，请重试';
    } finally {
      notifyListeners();
    }
  }

  Future<void> cancel() async {
    if (phase != AppUpdatePhase.downloading) return;
    await files.cancel();
  }

  // 安装包已核对过：没授权先引导开启；在后台就等回前台；否则拉起系统安装界面，停在可再点「安装」的状态。
  Future<void> _install() async {
    if (!await installer.canInstall()) {
      phase = AppUpdatePhase.needsPermission;
      return;
    }
    phase = AppUpdatePhase.readyToInstall;
    if (!_foreground()) {
      _installOnResume = true;
      return;
    }
    campusLog('[AppUpdate] action=install versionCode=${release?.versionCode}');
    await installer.install(_path!);
  }

  // 界面上的「安装」：用户关掉过系统安装界面时再拉起一次。
  Future<void> install() => _guarded('install', () async {
    if (_path == null) return;
    await _install();
  });

  // 界面上的「去开启」：回到前台时接着装。
  Future<void> openInstallSettings() => _guarded('install_settings', () async {
    _installOnResume = true;
    await installer.openInstallSettings();
  });

  // 由组合根在应用回到前台时调用。
  Future<void> resume() async {
    if (!_installOnResume || _path == null) return;
    _installOnResume = false;
    await _guarded('resume', _install);
  }

  // 启动时清掉装好后的旧安装包与中断的残留。
  Future<void> prune() async {
    try {
      await files.prune(installedVersionCode);
    } catch (failure, stack) {
      campusLog('[AppUpdate] action=prune errorType=${failure.runtimeType}\n$stack');
    }
  }

  Future<void> _guarded(String action, Future<void> Function() body) async {
    try {
      await body();
    } catch (failure, stack) {
      campusLog('[AppUpdate] action=$action errorType=${failure.runtimeType}\n$stack');
      phase = AppUpdatePhase.failed;
      error = '没能打开系统安装，请到发布页下载';
    } finally {
      notifyListeners();
    }
  }

  void _enter(AppUpdatePhase next) {
    phase = next;
    notifyListeners();
  }
}
