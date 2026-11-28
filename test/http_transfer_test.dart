import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/download/http_transfer.dart';
import 'package:superxd/toolbox/download/toolbox_download_manager.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_resource_manager.dart';
import 'package:superxd/toolbox/toolbox_store.dart';

import 'toolbox_test_support.dart';

void main() {
  late Directory directory;
  late List<String> logs;
  final previousLog = campusLog;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('http_transfer_test');
    logs = [];
    campusLog = logs.add;
  });
  tearDown(() async {
    campusLog = previousLog;
    await directory.delete(recursive: true);
  });
  ToolboxDownload download(String id, String url) => ToolboxDownload(
    id: id,
    toolId: 'short_video',
    kind: ToolboxDownloadKind.video,
    filename: '$id.part',
    createdAt: DateTime.utc(2026, 10, 28),
    updatedAt: DateTime.utc(2026, 10, 28),
    state: ToolboxDownloadState.queued,
    url: Uri.parse(url),
  );
  File file(String id) => File('${directory.path}/$id.part');
  Future<void> received(HttpTransfer transfer, String id, double progress) async {
    while (((await transfer.lookup(id))?.progress ?? 0) < progress) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('整个下完写进下载目录，交出去校验并带上去掉参数的类型', () async {
    final transfer = HttpTransfer(
      directory.path,
      createClient: () => MockClient.streaming((request, _) async => http.StreamedResponse(
        Stream.value(List.filled(10, 7)),
        200,
        contentLength: 10,
        headers: {'content-type': 'video/mp4; charset=binary', 'accept-ranges': 'bytes'},
      )),
    );
    final done = transfer.updates.firstWhere((update) => update.state == ToolboxDownloadState.verifying);
    await transfer.enqueue(download('a', 'https://cdn.example.com/a.mp4'));
    final update = await done;
    expect(update.mimeType, 'video/mp4');
    expect(update.totalBytes, 10);
    expect(await file('a').readAsBytes(), List.filled(10, 7));
    await transfer.close();
  });

  // 11-28 Codex 审查 F08：原来写盘错误要等网络读完才接住，在那之前先成了没人处理的异步错误、下载还在等网络。
  test('写不了盘（目录不在）：网络还没读完就按失败结束、不再收网络，错误不逃出下载', () async {
    final escaped = <Object>[];
    final body = StreamController<List<int>>();
    final ended = Completer<(ToolboxTransferUpdate, bool)>();
    // 出错的 zone 里 future 不往外传错，结果经 ended 交出来、断言在外面做。
    unawaited(runZonedGuarded(() async {
      final transfer = HttpTransfer('${directory.path}/missing', createClient: () => MockClient.streaming((_, _) async => http.StreamedResponse(body.stream, 200, contentLength: 2)));
      final failed = transfer.updates.firstWhere((update) => update.state == ToolboxDownloadState.failed);
      await transfer.enqueue(download('a', 'https://cdn.example.com/a.mp4'));
      body.add([1]);
      final update = await failed;
      final open = !body.isClosed;
      await transfer.close();
      ended.complete((update, open));
    }, (error, stack) => escaped.add(error)));
    final (update, networkOpen) = await ended.future.timeout(const Duration(seconds: 5));
    expect(update.error, '下载失败，链接可能已失效，请重新解析');
    expect(networkOpen, isTrue, reason: '网络还没读完就结束了');
    expect(escaped, isEmpty);
    expect(body.hasListener, isFalse);
    expect(logs.single, startsWith('[ToolboxDownload] action=transfer errorType=PathNotFoundException'));
    // 没人听过的流，close 的 future 不会完成。
    unawaited(body.close());
  });

  // 11-28 Codex 复核 F08：上面那条在打开文件时就失败，没测到「已经写了一部分之后写盘出错」「写到一半取消」「关文件出错」与慢磁盘背压。
  // 用 IOOverrides 把下载目录里的 .part 文件换成按脚本写的（第几块出错、写之前等闸门、关文件出错），其余照真文件。
  group('写盘途中', () {
    // 跑在换了文件的 zone 里，错误逃没逃出来经 escaped 记下（zone 里的 future 不往外传错，结果经 Completer 交出来）。
    Future<T> onDisk<T>(_WriteScript script, List<Object> escaped, Future<T> Function() body) {
      final result = Completer<T>();
      runZonedGuarded(() => IOOverrides.runWithIOOverrides(() async => result.complete(await body()), _DiskOverrides(script)), (error, stack) {
        escaped.add(error);
        if (!result.isCompleted) result.completeError(error, stack);
      });
      return result.future.timeout(const Duration(seconds: 10));
    }

    test('已经写进一块、第二块磁盘满：立即按失败结束（能续传也不当成暂停），取消正在收的网络，错误不逃出下载', () async {
      final script = _WriteScript()..failAtWrite = 2;
      final escaped = <Object>[];
      var upstreamCancelled = false;
      final body = StreamController<List<int>>(onCancel: () => upstreamCancelled = true);
      final update = await onDisk(script, escaped, () async {
        final transfer = HttpTransfer(directory.path, createClient: () => MockClient.streaming((_, _) async => http.StreamedResponse(body.stream, 200, contentLength: 30, headers: {'accept-ranges': 'bytes'})));
        final failed = transfer.updates.firstWhere((update) => update.state == ToolboxDownloadState.failed || update.state == ToolboxDownloadState.paused);
        await transfer.enqueue(download('a', 'https://cdn.example.com/a.mp4'));
        body.add(List.filled(10, 1));
        await script.written(1);
        body.add(List.filled(10, 2));
        final update = await failed;
        await transfer.close();
        return update;
      });
      expect(update.state, ToolboxDownloadState.failed);
      expect(update.error, '下载失败，链接可能已失效，请重新解析');
      expect(upstreamCancelled, isTrue, reason: '正在收的上游被取消');
      expect(body.isClosed, isFalse, reason: '网络还没读完就结束了');
      expect(escaped, isEmpty);
      expect(await file('a').readAsBytes(), List.filled(10, 1), reason: '第一块留在盘上');
      expect(logs.where((line) => line.startsWith('[ToolboxDownload] action=transfer errorType=FileSystemException')), hasLength(1));
    });

    test('慢磁盘：一块没写完时网络停着不收（上游被暂停），写完才收下一块；最后完整下完', () async {
      final script = _WriteScript()..gate = Completer<void>();
      final escaped = <Object>[];
      final body = StreamController<List<int>>();
      final pausedWhileWriting = <bool>[];
      final update = await onDisk(script, escaped, () async {
        final transfer = HttpTransfer(directory.path, createClient: () => MockClient.streaming((_, _) async => http.StreamedResponse(body.stream, 200, contentLength: 30)));
        final done = transfer.updates.firstWhere((update) => update.state == ToolboxDownloadState.verifying);
        await transfer.enqueue(download('a', 'https://cdn.example.com/a.mp4'));
        body.add(List.filled(10, 1));
        await script.entered(1);
        pausedWhileWriting.add(body.isPaused);
        body
          ..add(List.filled(10, 2))
          ..add(List.filled(10, 3));
        await pumpEventQueue();
        pausedWhileWriting.add(script.writes == 1);
        script.gate!.complete();
        await body.close();
        final update = await done;
        await transfer.close();
        return update;
      });
      expect(pausedWhileWriting, [true, true], reason: '写第一块时上游暂停、第二块还没开始写');
      expect(update.totalBytes, 30);
      expect(script.writes, 3);
      expect(await file('a').readAsBytes(), [...List.filled(10, 1), ...List.filled(10, 2), ...List.filled(10, 3)]);
      expect(escaped, isEmpty);
    });

    test('写到一半取消：等在写的那一块写完、关好文件再结束，不再写下一块，取消上游，不交去校验', () async {
      final script = _WriteScript()..gate = Completer<void>();
      final escaped = <Object>[];
      var upstreamCancelled = false;
      final body = StreamController<List<int>>(onCancel: () => upstreamCancelled = true);
      final states = <ToolboxDownloadState>[];
      await onDisk(script, escaped, () async {
        final transfer = HttpTransfer(directory.path, createClient: () => MockClient.streaming((_, _) async => http.StreamedResponse(body.stream, 200, contentLength: 30)));
        final listening = transfer.updates.listen((update) => states.add(update.state));
        await transfer.enqueue(download('a', 'https://cdn.example.com/a.mp4'));
        body.add(List.filled(10, 1));
        await script.entered(1);
        final cancelling = transfer.cancel('a');
        await pumpEventQueue();
        script.gate!.complete();
        await cancelling;
        body.add(List.filled(10, 2));
        await pumpEventQueue();
        await listening.cancel();
        await transfer.close();
      });
      expect(script.writes, 1);
      expect(script.closed, isTrue, reason: '文件关好了');
      expect(upstreamCancelled, isTrue);
      expect(states, isNot(contains(ToolboxDownloadState.verifying)));
      expect(escaped, isEmpty);
    });

    test('全收完、关文件时出错：按失败结束，不交去校验，记下错误', () async {
      final script = _WriteScript()..failClose = true;
      final escaped = <Object>[];
      final update = await onDisk(script, escaped, () async {
        final transfer = HttpTransfer(directory.path, createClient: () => MockClient.streaming((_, _) async => http.StreamedResponse(Stream.value(List.filled(10, 7)), 200, contentLength: 10)));
        final ended = transfer.updates.firstWhere((update) => update.state != ToolboxDownloadState.downloading && update.state != ToolboxDownloadState.queued);
        await transfer.enqueue(download('a', 'https://cdn.example.com/a.mp4'));
        final update = await ended;
        await transfer.close();
        return update;
      });
      expect(update.state, ToolboxDownloadState.failed);
      expect(escaped, isEmpty);
      expect(logs.where((line) => line.startsWith('[ToolboxDownload] action=transfer errorType=FileSystemException')), hasLength(1));
    });
  });

  test('跳转逐跳只认公网 https，跳到明文地址按失败处理', () async {
    final requested = <Uri>[];
    final transfer = HttpTransfer(
      directory.path,
      createClient: () => MockClient.streaming((request, _) async {
        requested.add(request.url);
        return requested.length == 1
            ? http.StreamedResponse(const Stream.empty(), 302, headers: {'location': 'https://cdn2.example.com/a.mp4'}, isRedirect: true)
            : http.StreamedResponse(const Stream.empty(), 302, headers: {'location': 'http://cdn3.example.com/a.mp4'}, isRedirect: true);
      }),
    );
    final failed = transfer.updates.firstWhere((update) => update.state == ToolboxDownloadState.failed);
    await transfer.enqueue(download('a', 'https://cdn.example.com/a.mp4'));
    expect((await failed).error, '下载失败，链接可能已失效，请重新解析');
    expect(requested.map((uri) => uri.host), ['cdn.example.com', 'cdn2.example.com']);
    await transfer.close();
  });

  test('404 等非成功状态按失败处理，日志只记状态码', () async {
    final transfer = HttpTransfer(
      directory.path,
      createClient: () => MockClient.streaming((request, _) async => http.StreamedResponse(Stream.value('<html>gone</html>'.codeUnits), 404)),
    );
    final failed = transfer.updates.firstWhere((update) => update.state == ToolboxDownloadState.failed);
    await transfer.enqueue(download('a', 'https://cdn.example.com/a.mp4'));
    expect((await failed).error, '下载失败，链接可能已失效，请重新解析');
    expect(logs, ['[ToolboxDownload] action=transfer errorType=HttpStatus http=404']);
    await transfer.close();
  });

  test('暂停后继续按 Range 从断点接着下，带上 ETag 核对文件没变', () async {
    final requests = <http.BaseRequest>[];
    final first = StreamController<List<int>>();
    final transfer = HttpTransfer(
      directory.path,
      createClient: () => MockClient.streaming((request, _) async {
        requests.add(request);
        return requests.length == 1
            ? http.StreamedResponse(first.stream, 200, contentLength: 10, headers: {'accept-ranges': 'bytes', 'etag': '"v1"', 'content-type': 'video/mp4'})
            : http.StreamedResponse(Stream.value(List.filled(6, 2)), 206, contentLength: 6, headers: {'content-range': 'bytes 4-9/10'});
      }),
    );
    await transfer.enqueue(download('a', 'https://cdn.example.com/a.mp4'));
    first.add(List.filled(4, 1));
    await received(transfer, 'a', 0.4);
    expect(await transfer.pause('a'), isTrue);
    expect((await transfer.lookup('a'))!.state, ToolboxDownloadState.paused);
    final done = transfer.updates.firstWhere((update) => update.state == ToolboxDownloadState.verifying);
    expect(await transfer.resume('a'), isTrue);
    await done;
    expect(requests.last.headers['range'], 'bytes=4-');
    expect(requests.last.headers['if-range'], '"v1"');
    expect(await file('a').readAsBytes(), [...List.filled(4, 1), ...List.filled(6, 2)]);
    await transfer.close();
  });

  test('收到一半断开：能续传的停在已暂停不报错，不能续传的按失败，都不自动重试', () async {
    for (final resumable in [true, false]) {
      var calls = 0;
      final body = StreamController<List<int>>();
      final transfer = HttpTransfer(
        directory.path,
        createClient: () => MockClient.streaming((request, _) async {
          calls++;
          return http.StreamedResponse(body.stream, 200, contentLength: 10, headers: {if (resumable) 'accept-ranges': 'bytes'});
        }),
      );
      final stopped = transfer.updates.firstWhere((update) => update.state != ToolboxDownloadState.downloading);
      await transfer.enqueue(download('a', 'https://cdn.example.com/a.mp4'));
      body.add(List.filled(4, 1));
      await received(transfer, 'a', 0.4);
      body.addError(const SocketException('connection reset'));
      final update = await stopped;
      expect(update.state, resumable ? ToolboxDownloadState.paused : ToolboxDownloadState.failed);
      expect(update.error, resumable ? isNull : '下载失败，链接可能已失效，请重新解析');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
      await transfer.close();
    }
  });

  test('接在下载管理上走完下载、按文件头校验与导出', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final store = await ToolboxStore.open(path.join(directory.path, 'toolbox.db'));
    final publisher = FakePublisher();
    final manager = ToolboxDownloadManager(
      store: store,
      transfer: HttpTransfer(
        path.join(directory.path, 'downloads'),
        createClient: () => MockClient.streaming((request, _) async => http.StreamedResponse(
          Stream.value(ToolboxFixture.mp4),
          200,
          contentLength: ToolboxFixture.mp4.length,
          headers: {'content-type': 'video/mp4'},
        )),
      ),
      publisher: publisher,
      directory: Directory(path.join(directory.path, 'downloads')),
      resources: ToolboxResourceManager(directory: Directory(path.join(directory.path, 'resources')), store: store, specifications: const {}),
    );
    await manager.initialize();
    final [id] = await manager.enqueue(
      toolId: 'short_video',
      title: '合成视频',
      identity: 'work',
      items: [ToolboxDownloadRequest(id: 'video', url: Uri.parse('https://cdn.example.com/video.mp4'), kind: ToolboxDownloadKind.video)],
    );
    while (manager.byId(id)!.state != ToolboxDownloadState.saved) {
      expect(manager.byId(id)!.state, isNot(ToolboxDownloadState.failed));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(manager.byId(id)!.mimeType, 'video/mp4');
    expect(publisher.published, contains(id));
    await manager.close();
    await store.close();
  });

  test('已收到数据却不能续传的不给暂停；取消后不再有进度', () async {
    final body = StreamController<List<int>>();
    final transfer = HttpTransfer(
      directory.path,
      createClient: () => MockClient.streaming((request, _) async => http.StreamedResponse(body.stream, 200, contentLength: 10)),
    );
    await transfer.enqueue(download('a', 'https://cdn.example.com/a.mp4'));
    body.add(List.filled(4, 1));
    await received(transfer, 'a', 0.4);
    expect(await transfer.pause('a'), isFalse);
    final updates = <ToolboxTransferUpdate>[];
    transfer.updates.listen(updates.add);
    await transfer.cancel('a');
    expect(body.hasListener, isFalse);
    expect(updates, isEmpty);
    await transfer.close();
  });
}

// 写盘脚本：第几次写出错（磁盘满）、每次写之前等的闸门、关文件出错；记下写了几次、关没关。
class _WriteScript {
  int? failAtWrite;
  Completer<void>? gate;
  bool failClose = false;
  int writes = 0;
  bool closed = false;
  final _entered = <int, Completer<void>>{};
  final _written = <int, Completer<void>>{};
  Future<void> entered(int index) => _entered.putIfAbsent(index, Completer.new).future;
  Future<void> written(int index) => _written.putIfAbsent(index, Completer.new).future;
}

final class _DiskOverrides extends IOOverrides {
  _DiskOverrides(this.script);
  final _WriteScript script;
  @override
  File createFile(String path) => path.endsWith('.part') ? _ScriptedFile(super.createFile(path), script) : super.createFile(path);
}

// 只拦 open（下载只用到它），交出按脚本写的文件；别的方法用不到。
class _ScriptedFile implements File {
  _ScriptedFile(this._real, this._script);
  final File _real;
  final _WriteScript _script;
  @override
  String get path => _real.path;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async => _ScriptedRandomAccessFile(await _real.open(mode: mode), _script);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _ScriptedRandomAccessFile implements RandomAccessFile {
  _ScriptedRandomAccessFile(this._real, this._script);
  final RandomAccessFile _real;
  final _WriteScript _script;
  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer, [int start = 0, int? end]) async {
    final index = ++_script.writes;
    _script._entered.putIfAbsent(index, Completer.new).complete();
    if (_script.gate case final gate?) await gate.future;
    if (index == _script.failAtWrite) throw const FileSystemException('No space left on device', '', OSError('No space left on device', 28));
    await _real.writeFrom(buffer, start, end);
    _script._written.putIfAbsent(index, Completer.new).complete();
    return this;
  }

  @override
  Future<void> close() async {
    await _real.close();
    _script.closed = true;
    if (_script.failClose) throw const FileSystemException('close failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}
