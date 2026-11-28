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
