import 'dart:async';

import 'package:superxd/application/app_updates.dart';
import 'package:superxd/domain/app_update.dart';
import 'package:superxd/local/app_update_memory.dart';

// 应用更新的测试替身：清单、安装包文件、系统安装器都在内存里，下载可用闸门停在半路看中间态。

const fakeSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

AppRelease fakeRelease({int versionCode = 5, int minSupported = 0, bool withApk = true, String notes = '修了一些问题'}) => AppRelease(
  versionCode: versionCode,
  versionName: '1.0.0-alpha.$versionCode',
  publishedAt: DateTime.utc(2026, 10, 16),
  minSupportedVersionCode: minSupported,
  notes: notes,
  releasePage: Uri.parse('https://github.com/huverse/SuperXD/releases/tag/v1.0.0-alpha.$versionCode'),
  apk: withApk ? AppReleaseApk(url: Uri.parse('http://relay.test/v1/app/files/SuperXD-$versionCode.apk'), size: 120 * 1048576, sha256: fakeSha) : null,
);

class FakeReleaseFeed implements AppReleaseFeed {
  AppRelease? next;
  AppUpdateException? error;
  int calls = 0;

  @override
  Future<AppRelease?> latest() async {
    calls++;
    if (error case final error?) throw error;
    return next;
  }
}

class FakePackageFiles implements AppPackageFiles {
  final stored = <String, String>{};
  // 下载写进去的内容的哈希；改成别的值模拟下坏了。
  String downloadedSha = fakeSha;
  // 不为空时下载停在半路（进度 50%），完成它才继续。
  Completer<void>? gate;
  int downloads = 0;
  int? prunedBelow;
  bool _cancelled = false;

  @override
  Future<String> pathFor(AppRelease release) async => '/cache/app_update/SuperXD-${release.versionCode}.apk';

  @override
  Future<bool> exists(String path) async => stored.containsKey(path);

  @override
  Future<void> download(Uri url, String path, {required void Function(double progress) onProgress}) async {
    downloads++;
    _cancelled = false;
    onProgress(.5);
    if (gate case final gate?) await gate.future;
    if (_cancelled) throw const AppUpdateCancelled();
    stored[path] = downloadedSha;
    onProgress(1);
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    final pending = gate;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  @override
  Future<String> sha256Of(String path) async => stored[path]!;

  @override
  Future<void> delete(String path) async => stored.remove(path);

  @override
  Future<void> prune(int installedVersionCode) async => prunedBelow = installedVersionCode;
}

class FakeInstaller implements AppInstaller {
  bool allowed = true;
  AppPackageIdentity? identity;
  final installs = <String>[];
  int settingsOpened = 0;

  @override
  Future<bool> canInstall() async => allowed;

  @override
  Future<void> openInstallSettings() async => settingsOpened++;

  @override
  Future<AppPackageIdentity> inspect(String path) async =>
      identity ?? AppPackageIdentity(samePackage: true, versionCode: int.parse(RegExp(r'SuperXD-(\d+)').firstMatch(path)![1]!), sameSigner: true);

  @override
  Future<void> install(String path) async => installs.add(path);
}

class UpdateFixture {
  UpdateFixture({int installed = 4, DateTime? now}) : now = now ?? DateTime.utc(2026, 10, 15, 2) {
    updates = AppUpdates(feed: feed, files: files, installer: installer, memory: memory, installedVersionCode: installed, foreground: () => foreground, clock: () => this.now);
  }
  final feed = FakeReleaseFeed();
  final files = FakePackageFiles();
  final installer = FakeInstaller();
  final memory = FileAppUpdateMemory.memory();
  DateTime now;
  bool foreground = true;
  late final AppUpdates updates;
}
