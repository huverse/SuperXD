import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_url.dart';
import 'package:superxd/domain/campus_log.dart';

final _contentRange = RegExp(r'^bytes (\d+)-\d+/(\d+|\*)$');

// iOS 的传输：在应用自己的进程里用 package:http 边收边写文件，不经系统后台下载服务。
// [人工决策-2026-10-28 16:47:45] 用户选定「iOS 改用应用自己下载」（主流应用对几 MB 的短视频与图片也是进程内下载）：
// 自签（全能签）的包里系统后台下载服务建不了临时文件（日志「无法创建文件」，即 NSURLErrorCannotCreateFile），两台 iPhone 全部失败，链接与安卓都正常。
// 代价是切到后台久了会被系统挂起：中断时已下的部分留着、停在已暂停，点继续按 Range 断点续传；不自动重试。安卓照旧用 BackgroundTransfer。
class HttpTransfer implements ToolboxTransfer {
  HttpTransfer(this.directory, {http.Client Function()? createClient}) : _createClient = createClient ?? http.Client.new;
  final String directory;
  final http.Client Function() _createClient;
  final _updates = StreamController<ToolboxTransferUpdate>.broadcast();
  final _tasks = <String, _HttpTask>{};
  // 等响应头、两块数据之间各最多等这么久（同 BackgroundTransfer 的 requestTimeout）。
  static const _timeout = Duration(seconds: 30);
  static const _failure = '下载失败，链接可能已失效，请重新解析';
  @override
  Stream<ToolboxTransferUpdate> get updates => _updates.stream;

  ToolboxTransferUpdate _update(String id, _HttpTask task, {String? error}) => ToolboxTransferUpdate(
    id,
    task.state,
    progress: task.total > 0 ? task.received / task.total : 0,
    totalBytes: task.total,
    mimeType: task.mimeType,
    error: error,
  );

  void _emit(String id, _HttpTask task, {String? error}) {
    if (!_updates.isClosed) _updates.add(_update(id, task, error: error));
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> enqueue(ToolboxDownload download) async {
    final task = _tasks[download.id] = _HttpTask(download.url!, File(path.join(directory, download.filename)));
    _start(download.id, task);
  }

  void _start(String id, _HttpTask task) {
    final stop = task.stop = Completer<void>();
    task.state = ToolboxDownloadState.downloading;
    task.running = _transfer(id, task, stop);
  }

  Future<void> _transfer(String id, _HttpTask task, Completer<void> stop) async {
    final client = _createClient();
    final watch = Stopwatch()..start();
    var uri = task.url;
    int? status;
    IOSink? sink;
    try {
      late http.StreamedResponse response;
      // 跳转自己跟：每一跳都得是公网 https，同解析结果与预览图的规则。
      for (var redirect = 0; ; redirect++) {
        if (redirect == 5) throw const FormatException('跳转过多');
        final request = http.AbortableRequest('GET', uri, abortTrigger: stop.future)..followRedirects = false;
        if (task.received > 0) {
          request.headers['range'] = 'bytes=${task.received}-';
          if (task.validator case final validator?) request.headers['if-range'] = validator;
        }
        response = await client.send(request).timeout(_timeout);
        if (!response.isRedirect) break;
        final location = response.headers['location'];
        await response.stream.listen(null).cancel();
        if (location == null) throw const FormatException('缺少跳转地址');
        uri = toolboxPublicUrl(uri.resolve(location).toString(), httpsOnly: true);
      }
      status = response.statusCode;
      final range = _contentRange.firstMatch(response.headers['content-range'] ?? '');
      final resumed = status == 206 && task.received > 0 && range != null && int.parse(range[1]!) == task.received;
      if (stop.isCompleted || (status != 200 && !resumed)) {
        await response.stream.listen(null).cancel();
        if (stop.isCompleted) return;
        campusLog('[ToolboxDownload] action=transfer errorType=HttpStatus http=$status');
        task.state = ToolboxDownloadState.failed;
        _emit(id, task, error: _failure);
        return;
      }
      if (resumed) {
        task.total = int.tryParse(range[2]!) ?? -1;
      } else {
        // 整个重下（第一次，或续传时对方不认 Range、文件已变）：记下能否续传与核对续传用的 ETag 或修改时间。
        final etag = response.headers['etag'];
        task
          ..received = 0
          ..total = response.contentLength ?? -1
          ..resumable = response.headers['accept-ranges'] == 'bytes'
          ..validator = etag != null && !etag.startsWith('W/') ? etag : response.headers['last-modified']
          ..mimeType = response.headers['content-type']?.split(';').first.trim();
      }
      _emit(id, task);
      final open = sink = task.file.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      final body = Completer<void>();
      final reported = Stopwatch()..start();
      final subscription = response.stream.timeout(_timeout).listen(
        (chunk) {
          open.add(chunk);
          task.received += chunk.length;
          if (reported.elapsed >= const Duration(milliseconds: 300)) {
            reported.reset();
            _emit(id, task);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!body.isCompleted) body.completeError(error, stack);
        },
        onDone: () {
          if (!body.isCompleted) body.complete();
        },
        cancelOnError: true,
      );
      unawaited(stop.future.then((_) async {
        await subscription.cancel();
        if (!body.isCompleted) body.complete();
      }));
      await body.future;
      sink = null;
      await open.close();
      if (stop.isCompleted) return;
      if (task.total >= 0 && task.received != task.total) throw const FormatException('下载不完整');
      task.state = ToolboxDownloadState.verifying;
      _emit(id, task);
    } catch (error, stack) {
      if (stop.isCompleted) return;
      campusLog('[ToolboxDownload] action=transfer errorType=${error.runtimeType}\n$stack');
      // 已下了一部分且能续传的停在已暂停（多半是切到后台被系统挂起），点继续接着下；其余按失败。
      task.state = task.received > 0 && task.resumable ? ToolboxDownloadState.paused : ToolboxDownloadState.failed;
      _emit(id, task, error: task.state == ToolboxDownloadState.failed ? _failure : null);
    } finally {
      await sink?.close().catchError((Object error, StackTrace stack) {
        campusLog('[ToolboxDownload] action=close errorType=${error.runtimeType}\n$stack');
      });
      client.close();
      campusRequestLog('toolbox_download', 'GET', uri, status: status, elapsed: watch.elapsed, bytes: task.received);
    }
  }

  Future<void> _stop(_HttpTask task) async {
    if (task.stop case final stop? when !stop.isCompleted) stop.complete();
    await task.running;
  }

  @override
  Future<void> cancel(String id) async {
    final task = _tasks[id];
    if (task != null) await _stop(task);
  }

  // 已收到数据却不能续传的不给暂停（下载管理据此提示取消后重新解析）；还没收到数据的暂停后从头再下。
  @override
  Future<bool> pause(String id) async {
    final task = _tasks[id];
    if (task == null || task.state != ToolboxDownloadState.downloading || (task.received > 0 && !task.resumable)) {
      return false;
    }
    await _stop(task);
    if (task.state == ToolboxDownloadState.downloading) task.state = ToolboxDownloadState.paused;
    return task.state != ToolboxDownloadState.failed;
  }

  @override
  Future<bool> resume(String id) async {
    final task = _tasks[id];
    if (task == null || task.state != ToolboxDownloadState.paused) return false;
    _start(id, task);
    return true;
  }

  // 只在内存里：应用被杀后查不到，下载管理按「下载已中断」处理。
  @override
  Future<ToolboxTransferUpdate?> lookup(String id) async {
    final task = _tasks[id];
    return task == null ? null : _update(id, task);
  }

  @override
  Future<void> forget(String id) async {
    final task = _tasks.remove(id);
    if (task != null) await _stop(task);
  }

  // 下载只在前台进行，不发通知，也就不申请通知权限。
  @override
  Future<void> requestNotifications() async {}

  @override
  Future<void> close() async {
    await Future.wait([for (final task in _tasks.values) _stop(task)]);
    await _updates.close();
  }
}

class _HttpTask {
  _HttpTask(this.url, this.file);
  final Uri url;
  final File file;
  ToolboxDownloadState state = ToolboxDownloadState.queued;
  int received = 0;
  int total = -1;
  bool resumable = false;
  String? mimeType;
  String? validator;
  Completer<void>? stop;
  Future<void>? running;
}
