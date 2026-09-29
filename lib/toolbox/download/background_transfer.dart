import 'dart:async';

import 'package:background_downloader/background_downloader.dart' as background;

import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/domain/campus_log.dart';

class BackgroundTransfer implements ToolboxTransfer {
  BackgroundTransfer(this.directory);
  final String directory;
  final _downloader = background.FileDownloader();
  final _updates = StreamController<ToolboxTransferUpdate>.broadcast();
  final _cancellations = <String, Completer<void>>{};
  final _pauses = <String, Completer<bool>>{};
  static const group = 'superxd_toolbox';
  @override
  Stream<ToolboxTransferUpdate> get updates => _updates.stream;

  ToolboxDownloadState _state(background.TaskStatus status) => switch (status) {
    background.TaskStatus.enqueued => ToolboxDownloadState.queued,
    background.TaskStatus.running ||
    background.TaskStatus.waitingToRetry => ToolboxDownloadState.downloading,
    background.TaskStatus.paused => ToolboxDownloadState.paused,
    background.TaskStatus.complete => ToolboxDownloadState.verifying,
    background.TaskStatus.canceled => ToolboxDownloadState.cancelled,
    _ => ToolboxDownloadState.failed,
  };

  @override
  Future<void> initialize() async {
    final results = await _downloader.configure(
      globalConfig: [
        (background.Config.requestTimeout, const Duration(seconds: 30)),
        (background.Config.checkAvailableSpace, 32),
      ],
      androidConfig: [
        (background.Config.holdingQueue, (2, 2, 2)),
        (background.Config.runInForeground, background.Config.never),
      ],
    );
    if (results.any((result) => result.$2.isNotEmpty)) {
      throw const ToolboxException('下载服务初始化失败');
    }
    _downloader.registerCallbacks(
      group: group,
      taskStatusCallback: (update) {
        if (update.exception != null) {
          campusLog(
            '[ToolboxDownload] action=transfer errorType=${update.exception.runtimeType}',
          );
        }
        if (update.status.isFinalState) {
          final cancellation = _cancellations.remove(update.task.taskId);
          if (cancellation != null && !cancellation.isCompleted) {
            cancellation.complete();
          }
        }
        if (update.status == background.TaskStatus.paused ||
            update.status.isFinalState) {
          final pause = _pauses.remove(update.task.taskId);
          if (pause != null && !pause.isCompleted) {
            pause.complete(update.status == background.TaskStatus.paused);
          }
        }
        _updates.add(
          ToolboxTransferUpdate(
            update.task.taskId,
            _state(update.status),
            mimeType: update.mimeType,
            error:
                update.status == background.TaskStatus.failed ||
                    update.status == background.TaskStatus.notFound
                ? '下载失败，链接可能已失效，请重新解析'
                : null,
          ),
        );
      },
      taskProgressCallback: (update) {
        if (update.progress >= 0) {
          _updates.add(
            ToolboxTransferUpdate(
              update.task.taskId,
              ToolboxDownloadState.downloading,
              progress: update.progress,
              totalBytes: update.expectedFileSize,
            ),
          );
        }
      },
    );
    _downloader.configureNotificationForGroup(
      group,
      running: const background.TaskNotification('百宝箱正在下载', '{progress}'),
      complete: const background.TaskNotification('传输完成', '打开百宝箱完成保存或资源校验'),
      error: const background.TaskNotification('下载未完成', '请在百宝箱查看'),
      progressBar: true,
    );
    await _downloader.trackTasksInGroup(group, markDownloadedComplete: false);
    await _downloader.resumeFromBackground();
  }

  @override
  Future<void> enqueue(ToolboxDownload download) async {
    final notifications =
        await _downloader.permissions.status(
          background.PermissionType.notifications,
        ) ==
        background.PermissionStatus.granted;
    // UIDT要求及时提供通知；插件在拒绝通知时跳过通知会触发ANR，此时用WorkManager普通任务。
    await _downloader.configure(
      androidConfig: [
        (
          background.Config.runInForeground,
          notifications ? background.Config.always : background.Config.never,
        ),
      ],
    );
    final accepted = await _downloader.enqueue(
      background.DownloadTask(
        taskId: download.id,
        url: download.url.toString(),
        baseDirectory: background.BaseDirectory.root,
        directory: directory,
        filename: download.filename,
        group: group,
        updates: background.Updates.statusAndProgress,
        retries: 0,
        allowPause: true,
        displayName: '百宝箱下载',
        priority: notifications ? 0 : 5,
      ),
    );
    if (!accepted) throw const ToolboxException('下载任务未能启动');
  }

  @override
  Future<void> cancel(String id) async {
    final current = await lookup(id);
    if (current == null ||
        !const {
          ToolboxDownloadState.queued,
          ToolboxDownloadState.downloading,
          ToolboxDownloadState.paused,
        }.contains(current.state)) {
      return;
    }
    final completion = _cancellations.putIfAbsent(id, Completer<void>.new);
    try {
      if (!await _downloader.cancelTaskWithId(id)) {
        throw const ToolboxException('取消未完成，请重试');
      }
      await completion.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () async {
          final latest = await lookup(id);
          if (latest != null &&
              const {
                ToolboxDownloadState.queued,
                ToolboxDownloadState.downloading,
              }.contains(latest.state)) {
            throw const ToolboxException('任务仍在停止，请稍后重试');
          }
        },
      );
    } finally {
      _cancellations.remove(id);
    }
  }

  @override
  Future<bool> pause(String id) async {
    final task = await _downloader.taskForId(id);
    if (task is! background.DownloadTask) return false;
    final completion = _pauses.putIfAbsent(id, Completer<bool>.new);
    try {
      if (!await _downloader.pause(task)) return false;
      return await completion.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () async =>
            (await lookup(id))?.state == ToolboxDownloadState.paused,
      );
    } finally {
      _pauses.remove(id);
    }
  }

  @override
  Future<bool> resume(String id) async {
    final record = await _downloader.database.recordForId(id);
    final task = record?.task;
    return task is background.DownloadTask && await _downloader.resume(task);
  }

  @override
  Future<ToolboxTransferUpdate?> lookup(String id) async {
    final record = await _downloader.database.recordForId(id);
    if (record == null) return null;
    if (record.status == background.TaskStatus.running &&
        await _downloader.taskForId(id) == null) {
      return ToolboxTransferUpdate(
        id,
        ToolboxDownloadState.failed,
        error: '下载已中断，请重新解析后下载',
      );
    }
    return ToolboxTransferUpdate(
      id,
      _state(record.status),
      progress: record.progress.clamp(0, 1),
      totalBytes: record.expectedFileSize,
    );
  }

  @override
  Future<void> forget(String id) => _downloader.database.deleteRecordWithId(id);
  @override
  Future<void> requestNotifications() async {
    if (await _downloader.permissions.status(
          background.PermissionType.notifications,
        ) !=
        background.PermissionStatus.granted) {
      await _downloader.permissions.request(
        background.PermissionType.notifications,
      );
    }
  }

  @override
  Future<void> close() async {
    _downloader.unregisterCallbacks(group: group);
    await _updates.close();
  }
}
