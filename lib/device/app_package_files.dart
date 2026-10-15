import 'dart:io';
import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart' as background;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/campus_log.dart';

// 安装包放在缓存的 app_update 文件夹（原生安装通道与 FileProvider 只认这里，见 AppUpdateInstaller.kt），只留一个版本。
const appUpdateDirectory = 'app_update';
final _packageName = RegExp(r'^SuperXD-(\d+)\.apk$');

// 安装包文件的实现：background_downloader 的独立命名空间下载（与百宝箱的下载组、回调互不相干），
// 应用退到后台照常下载；有通知权限时以前台任务跑并在通知栏显示进度。SHA-256 在后台 isolate 里算，不卡界面。
class CacheAppPackageFiles implements AppPackageFiles {
  CacheAppPackageFiles({Future<Directory> Function()? root}) : _root = root ?? _cacheRoot;
  final Future<Directory> Function() _root;
  // 用到下载时才取插件实例（只测文件清理与校验时不碰插件通道）。
  late final _downloader = background.FileDownloader.scoped('superxd_update');
  static const _group = 'app_update';
  bool _notificationReady = false;
  String? _taskId;

  static Future<Directory> _cacheRoot() async => Directory(path.join((await getTemporaryDirectory()).path, appUpdateDirectory));

  @override
  Future<String> pathFor(AppRelease release) async => path.join((await _root()).path, 'SuperXD-${release.versionCode}.apk');

  @override
  Future<bool> exists(String file) => File(file).exists();

  @override
  Future<void> download(Uri url, String target, {required void Function(double progress) onProgress}) async {
    final root = Directory(path.dirname(target));
    // 只留这一个安装包：先删缓存里别的版本与上次中断的残留。
    if (await root.exists()) {
      await for (final entity in root.list()) {
        if (entity.path != target) await entity.delete(recursive: true);
      }
    } else {
      await root.create(recursive: true);
    }
    await _prepare();
    final task = background.DownloadTask(
      url: url.toString(),
      filename: path.basename(target),
      directory: appUpdateDirectory,
      baseDirectory: background.BaseDirectory.temporary,
      group: _group,
      updates: background.Updates.statusAndProgress,
    );
    _taskId = task.taskId;
    campusLog('[AppUpdate] action=download_start file=${path.basename(target)}');
    final result = await _downloader.download(task, onProgress: (value) {
      if (value >= 0) onProgress(value);
    });
    _taskId = null;
    campusLog('[AppUpdate] action=download_end status=${result.status.name}');
    switch (result.status) {
      case background.TaskStatus.complete:
        return;
      case background.TaskStatus.canceled:
        throw const AppUpdateCancelled();
      default:
        campusLog('[AppUpdate] action=download errorType=${result.exception.runtimeType} httpCode=${result.responseStatusCode}');
        throw const AppUpdateException('下载没完成，请检查网络后重试');
    }
  }

  // 通知权限决定前台任务：UIDT 要求及时给通知，插件在没有通知权限时跳过通知会触发 ANR，此时改用普通 WorkManager 任务
  // （与百宝箱 background_transfer.dart 同一规则；这一项是插件全局配置，两边都在入队前按当下权限重设）。
  Future<void> _prepare() async {
    if (!_notificationReady) {
      _downloader.configureNotificationForGroup(
        _group,
        running: const background.TaskNotification('正在下载 SuperXD 新版本', '{progress}'),
        complete: const background.TaskNotification('新版本已下载', '回到 SuperXD 安装'),
        error: const background.TaskNotification('新版本没下载完', '打开 SuperXD 重试'),
        progressBar: true,
      );
      _notificationReady = true;
    }
    final notifications = await _downloader.permissions.status(background.PermissionType.notifications) == background.PermissionStatus.granted;
    await _downloader.configure(androidConfig: [(background.Config.runInForeground, notifications ? background.Config.always : background.Config.never)]);
  }

  @override
  Future<void> cancel() async {
    final taskId = _taskId;
    if (taskId != null) await _downloader.cancelTaskWithId(taskId);
  }

  @override
  Future<String> sha256Of(String file) => Isolate.run(() async => (await sha256.bind(File(file).openRead()).first).toString());

  @override
  Future<void> delete(String file) async {
    final target = File(file);
    if (await target.exists()) await target.delete();
  }

  @override
  Future<void> prune(int installedVersionCode) async {
    final root = await _root();
    if (!await root.exists()) return;
    await for (final entity in root.list()) {
      final match = _packageName.firstMatch(path.basename(entity.path));
      if (match != null && int.parse(match[1]!) > installedVersionCode) continue;
      await entity.delete(recursive: true);
      campusLog('[AppUpdate] action=prune file=${path.basename(entity.path)}');
    }
  }
}
