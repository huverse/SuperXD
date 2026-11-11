import 'package:background_downloader/background_downloader.dart' as background;
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/download/background_transfer.dart';
import 'package:superxd/toolbox/toolbox_models.dart';

void main() {
  late List<String> logs;
  late BackgroundTransfer transfer;
  late List<ToolboxTransferUpdate> updates;
  final task = background.DownloadTask(taskId: 'd1', url: 'https://cdn.example.com/a.mp4', filename: 'a.mp4', group: BackgroundTransfer.group);
  setUp(() {
    logs = [];
    final previous = campusLog;
    campusLog = logs.add;
    transfer = BackgroundTransfer('/data/toolbox/downloads');
    updates = [];
    final subscription = transfer.updates.listen(updates.add);
    addTearDown(() async {
      campusLog = previous;
      await subscription.cancel();
    });
  });

  test('插件的状态换成通用状态：失败与找不到才带「重新解析」的提示', () async {
    const expected = {
      background.TaskStatus.enqueued: ToolboxDownloadState.queued,
      background.TaskStatus.running: ToolboxDownloadState.downloading,
      background.TaskStatus.waitingToRetry: ToolboxDownloadState.downloading,
      background.TaskStatus.paused: ToolboxDownloadState.paused,
      background.TaskStatus.complete: ToolboxDownloadState.verifying,
      background.TaskStatus.canceled: ToolboxDownloadState.cancelled,
      background.TaskStatus.failed: ToolboxDownloadState.failed,
      background.TaskStatus.notFound: ToolboxDownloadState.failed,
    };
    expect(expected.keys, containsAll(background.TaskStatus.values), reason: '插件新增的状态要在这里想清楚归哪类');
    for (final status in expected.keys) {
      transfer.onStatus(background.TaskStatusUpdate(task, status));
    }
    await pumpEventQueue();
    expect(updates.map((update) => update.state), expected.values);
    expect([for (final update in updates) if (update.error != null) update.state], [ToolboxDownloadState.failed, ToolboxDownloadState.failed]);
    expect(updates.every((update) => update.id == 'd1'), isTrue);
  });

  test('失败原因进日志：HTTP 错误只记状态码不记正文，其余异常的描述压成一行，404 单独记一条', () async {
    transfer.onStatus(background.TaskStatusUpdate(task, background.TaskStatus.failed, background.TaskHttpException('<html>拒绝访问</html>', 403)));
    transfer.onStatus(background.TaskStatusUpdate(task, background.TaskStatus.failed, background.TaskConnectionException('连接\n   被重置')));
    transfer.onStatus(background.TaskStatusUpdate(task, background.TaskStatus.notFound, null, null, null, 404));
    transfer.onStatus(background.TaskStatusUpdate(task, background.TaskStatus.running));
    expect(logs, [
      '[ToolboxDownload] action=transfer errorType=TaskHttpException http=403',
      '[ToolboxDownload] action=transfer errorType=TaskConnectionException message=连接 被重置',
      '[ToolboxDownload] action=transfer errorType=NotFound http=404',
    ]);
  });

  test('进度：插件用负数表示失败等状态时不推进度，正常的带上总字节数；状态回调带上 mime', () async {
    transfer.onProgress(background.TaskProgressUpdate(task, -1));
    transfer.onProgress(background.TaskProgressUpdate(task, 0.5, 2048));
    transfer.onStatus(background.TaskStatusUpdate(task, background.TaskStatus.complete, null, null, null, 200, 'video/mp4'));
    await pumpEventQueue();
    expect([for (final update in updates) (update.state, update.progress, update.totalBytes)], [(ToolboxDownloadState.downloading, 0.5, 2048), (ToolboxDownloadState.verifying, 0.0, -1)]);
    expect(updates.last.mimeType, 'video/mp4');
  });

  test('交给插件的任务：不自动重试、可暂停、按通知权限排先后，写进给定的下载目录', () {
    final download = ToolboxDownload(
      id: 'd1',
      toolId: 'short_video',
      kind: ToolboxDownloadKind.values.first,
      filename: 'a.mp4',
      createdAt: DateTime.utc(2026, 11, 10),
      updatedAt: DateTime.utc(2026, 11, 10),
      state: ToolboxDownloadState.queued,
      url: Uri.parse('https://cdn.example.com/a.mp4'),
    );
    final granted = transfer.downloadTask(download, notifications: true);
    // 插件按根目录存相对路径（去掉开头的 /），这里比的是交给它的就是给定的下载目录。
    final directory = background.DownloadTask(url: 'https://cdn.example.com/a.mp4', baseDirectory: background.BaseDirectory.root, directory: '/data/toolbox/downloads').directory;
    expect((granted.taskId, granted.url, granted.filename, granted.directory, granted.baseDirectory), ('d1', 'https://cdn.example.com/a.mp4', 'a.mp4', directory, background.BaseDirectory.root));
    expect((granted.group, granted.retries, granted.allowPause, granted.updates, granted.priority), (BackgroundTransfer.group, 0, true, background.Updates.statusAndProgress, 0));
    expect(transfer.downloadTask(download, notifications: false).priority, 5);
  });
}
