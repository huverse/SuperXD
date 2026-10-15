import 'package:superxd/domain/campus_clock.dart';

// 应用内更新的领域类型、规则与端口：版本清单来自自建中转（发版时放上去的清单文件），
// 安装包下载到本机缓存，核对 SHA-256、包名、版本号与签名证书后交给系统安装器。

class AppReleaseApk {
  const AppReleaseApk({required this.url, required this.size, required this.sha256});
  final Uri url;
  final int size;
  // 小写十六进制。
  final String sha256;
}

class AppRelease {
  const AppRelease({
    required this.versionCode,
    required this.versionName,
    required this.publishedAt,
    required this.minSupportedVersionCode,
    required this.notes,
    required this.releasePage,
    required this.apk,
  });
  final int versionCode;
  final String versionName;
  final DateTime publishedAt;
  // 已装版本低于它时必须更新（只在旧版已无法正常使用时由发版人调高）。
  final int minSupportedVersionCode;
  final String notes;
  // 下载失败或没有这个架构的安装包时，用浏览器打开发布页。
  final Uri releasePage;
  final AppReleaseApk? apk;
}

enum AppUpdateUrgency { none, optional, forced }

// [人工决策-2026-10-15 14:06:35] 强制更新只认清单的最低可用版本：已装版本低于它且确有更新版本时必须更新，弹窗不可关闭；
// 平时一律可选（同大厂做法：强制只用于旧版已无法正常工作，如服务端接口不兼容、严重问题）。
AppUpdateUrgency appUpdateUrgency(int installedVersionCode, AppRelease release) {
  if (release.versionCode <= installedVersionCode) return AppUpdateUrgency.none;
  return installedVersionCode < release.minSupportedVersionCode ? AppUpdateUrgency.forced : AppUpdateUrgency.optional;
}

// [人工决策-2026-10-15 14:06:35] 启动后自动检查，每个校园日最多一次（按业务日界，不按 24 小时滚动）；手动检查不受限。
// 上次查到必须更新时不受这个限制。
bool appUpdateCheckDue(DateTime? lastCheckedAt, DateTime now, {required bool forcedPending}) =>
    forcedPending || lastCheckedAt == null || formatCampusDate(campusInstant(lastCheckedAt)) != formatCampusDate(campusInstant(now));

// 自动检查查到新版时要不要弹窗：强制更新总是弹；可选更新被「跳过这个版本」的不弹，更新的版本照常弹。
bool appUpdatePromptDue(AppUpdateUrgency urgency, AppRelease release, int? skippedVersionCode) => switch (urgency) {
  AppUpdateUrgency.forced => true,
  AppUpdateUrgency.optional => release.versionCode != skippedVersionCode,
  AppUpdateUrgency.none => false,
};

// 更新失败，message 只用于展示。
class AppUpdateException implements Exception {
  const AppUpdateException(this.message);
  final String message;
  @override
  String toString() => 'AppUpdateException($message)';
}

// 版本清单来源；这个渠道还没有发布版本时返回 null。网络或格式问题抛 AppUpdateException。
abstract class AppReleaseFeed {
  Future<AppRelease?> latest();
}

// 安装包在本机缓存里的存取：每个版本一个固定路径，下载可取消，校验算 SHA-256。
abstract class AppPackageFiles {
  Future<String> pathFor(AppRelease release);
  Future<bool> exists(String path);
  // 下载到 path（先删掉缓存里的其他安装包，只留这一个）；被 cancel 打断时抛 AppUpdateCancelled。
  Future<void> download(Uri url, String path, {required void Function(double progress) onProgress});
  Future<void> cancel();
  Future<String> sha256Of(String path);
  Future<void> delete(String path);
  // 删掉版本号不高于已装版本的安装包（装好新版后的残留）与下载中断留下的半截文件。
  Future<void> prune(int installedVersionCode);
}

class AppUpdateCancelled implements Exception {
  const AppUpdateCancelled();
}

// 安装包自报的身份：包名是否与本应用一致、版本号、签名证书是否与已装应用一致。
class AppPackageIdentity {
  const AppPackageIdentity({required this.samePackage, required this.versionCode, required this.sameSigner});
  final bool samePackage;
  final int versionCode;
  final bool sameSigner;
}

// 系统安装器：Android 8 起要用户允许本应用「安装未知应用」。
abstract class AppInstaller {
  Future<bool> canInstall();
  Future<void> openInstallSettings();
  Future<AppPackageIdentity> inspect(String path);
  Future<void> install(String path);
}

// 自动检查的记录：上次查成功的时刻、用户跳过的版本、上次是否查到必须更新，只存本机。
// 查到必须更新时每次启动都查（不受每天一次的限制），杀掉应用再开躲不过去；查到不再必须时清掉。
abstract class AppUpdateMemory {
  DateTime? get lastCheckedAt;
  int? get skippedVersionCode;
  bool get forcedPending;
  Future<void> save({required DateTime? lastCheckedAt, required int? skippedVersionCode, required bool forcedPending});
}
