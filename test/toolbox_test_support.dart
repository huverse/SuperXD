import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/toolbox/download/toolbox_download_manager.dart';
import 'package:superxd/toolbox/media_resource.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/short_video/parse_source.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_resource_manager.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/toolbox/toolbox_store.dart';

class ToolboxFixture {
  late final Directory directory;
  late final ToolboxStore store;
  late final ToolboxResourceManager resources;
  late final ToolboxDownloadManager manager;
  late final ToolboxRuntime runtime;
  final transfer = FakeTransfer();
  final publisher = FakePublisher();
  final parser = FakeVideoParser();
  static final video = ParseResult(
    sourceUrl: Uri.parse('https://example.com/work'),
    providerId: 'bugpk',
    title: '合成视频',
    author: '测试',
    resources: [
      MediaResource(
        id: 'video',
        kind: MediaKind.video,
        url: Uri.parse('https://cdn.example.com/video.mp4'),
        label: '视频',
      ),
    ],
  );
  Future<String> downloadVideo([ParseResult? result]) async {
    final value = result ?? video;
    return (await manager.downloadMedia(
      title: value.title,
      identity: value.identity,
      sourceUrl: value.sourceUrl,
      providerId: value.providerId,
      media: value.resources,
    )).first;
  }

  static const mp4 = [
    0,
    0,
    0,
    24,
    102,
    116,
    121,
    112,
    109,
    112,
    52,
    50,
    0,
    0,
    0,
    0,
    109,
    112,
    52,
    50,
    105,
    115,
    111,
    109,
  ];
  static const resourceBytes = [1, 2, 3, 4, 5];
  static final resource = ToolboxResource(
    version: '1',
    url: Uri.parse('https://cdn.example.com/data.bin'),
    bytes: resourceBytes.length,
    sha256: sha256.convert(resourceBytes).toString(),
  );

  Future<void> initialize() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 测试私有目录由测试框架清理，不碰用户课表/成绩或导出文件。
    final root = await Directory(
      path.join(Directory.current.path, 'build', 'toolbox_tests'),
    ).create(recursive: true);
    directory = await root.createTemp('case_');
    store = await ToolboxStore.open(path.join(directory.path, 'toolbox.db'));
    resources = ToolboxResourceManager(
      directory: Directory(path.join(directory.path, 'resources')),
      store: store,
      specifications: {'large_tool': resource},
    );
    manager = ToolboxDownloadManager(
      store: store,
      transfer: transfer,
      publisher: publisher,
      directory: Directory(path.join(directory.path, 'downloads')),
      resources: resources,
    );
    await manager.initialize();
    runtime = ToolboxRuntime.testing(
      catalog: toolboxCatalog,
      store: store,
      downloads: manager,
      parser: parser,
    );
  }

  Future<void> finish(String id, List<int> bytes, {String? mimeType}) async {
    await manager.file(manager.byId(id)!).writeAsBytes(bytes);
    transfer.send(
      ToolboxTransferUpdate(
        id,
        ToolboxDownloadState.verifying,
        mimeType: mimeType,
      ),
    );
  }

  Future<void> waitFor(String id, ToolboxDownloadState state) async {
    final watch = Stopwatch()..start();
    while (manager.byId(id)?.state != state &&
        watch.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(manager.byId(id)?.state, state);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  // 待保存先以无错误的排队态出现，导出失败后才带上错误；断言失败态要等错误真正写入，不能以“待保存”代替。
  Future<void> waitForSaveFailed(String id) async {
    final watch = Stopwatch()..start();
    while (manager.byId(id)?.saveFailed != true &&
        watch.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(manager.byId(id)?.saveFailed, isTrue);
  }

  // 下一项在前一项状态落定后才异步入队；断言入队数前要等到真实入队，不能以“已保存”代替。
  Future<void> waitForEnqueued(int count) async {
    final watch = Stopwatch()..start();
    while (transfer.enqueueCount < count &&
        watch.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (transfer.enqueueCount < count) {
      fail('等待超时：入队数达到 $count（实际 ${transfer.enqueueCount}）');
    }
  }

  Future<void> close() async {
    // 断言失败时导出闸门可能没放开，close 会一直等在途导出直到超时。
    if (publisher.gate case final gate? when !gate.isCompleted) gate.complete();
    await runtime.close();
    await directory.delete(recursive: true);
  }
}

class FakeTransfer implements ToolboxTransfer {
  final controller = StreamController<ToolboxTransferUpdate>.broadcast();
  final records = <String, ToolboxTransferUpdate>{};
  int enqueueCount = 0;
  Completer<void>? cancellation;
  Completer<void>? notificationPermission;
  Completer<void>? enqueueGate;
  @override
  Stream<ToolboxTransferUpdate> get updates => controller.stream;
  void send(ToolboxTransferUpdate update) {
    records[update.id] = update;
    controller.add(update);
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<void> enqueue(ToolboxDownload download) async {
    await enqueueGate?.future;
    enqueueCount++;
    records[download.id] = ToolboxTransferUpdate(
      download.id,
      ToolboxDownloadState.queued,
    );
  }

  @override
  Future<void> cancel(String id) async {
    await cancellation?.future;
    records[id] = ToolboxTransferUpdate(id, ToolboxDownloadState.cancelled);
  }

  bool canPause = true;
  @override
  Future<bool> pause(String id) async {
    if (!canPause) return false;
    records[id] = ToolboxTransferUpdate(id, ToolboxDownloadState.paused);
    return true;
  }

  @override
  Future<bool> resume(String id) async {
    records[id] = ToolboxTransferUpdate(id, ToolboxDownloadState.downloading);
    return true;
  }

  @override
  Future<ToolboxTransferUpdate?> lookup(String id) async => records[id];
  @override
  Future<void> forget(String id) async {
    records.remove(id);
  }

  @override
  Future<void> requestNotifications() async {
    await notificationPermission?.future;
  }

  @override
  Future<void> close() async {
    await controller.close();
  }
}

class FakePublisher implements ToolboxFilePublisher {
  bool fail = false;
  bool cancel = false;
  int calls = 0;
  // 拖住导出，模拟真机 MediaStore 写入与哈希校验慢、后续项排队等导出。
  Completer<void>? gate;
  final published = <String, Uri>{};
  // publishExternal 的最近一次参数（人脸照片保存等一次性导出用）。
  String? externalFilename;
  String? externalSource;
  @override
  Future<Uri?> publish({
    required String id,
    required String source,
    required String filename,
    required String mimeType,
  }) async {
    calls++;
    await gate?.future;
    if (fail) throw const ToolboxException('存储空间不足');
    if (cancel) return null;
    return published.putIfAbsent(
      id,
      () => Uri.parse('content://media/downloads/$id'),
    );
  }

  @override
  Future<Uri?> publishExternal({
    required String source,
    required String filename,
    required String mimeType,
  }) async {
    calls++;
    externalSource = source;
    externalFilename = filename;
    await gate?.future;
    if (fail) throw const ToolboxException('存储空间不足');
    if (cancel) return null;
    return published.putIfAbsent(
      filename,
      () => Uri.parse('content://media/external/$filename'),
    );
  }

  @override
  Future<void> open(Uri uri, String mimeType) async {}
}

class FakeVideoParser implements ParseProvider {
  int calls = 0;
  @override
  final source = const ParseSource(
    id: 'bugpk',
    name: 'BugPK',
    host: 'api.bugpk.com',
    version: '2',
    consentVersion: 'bugpk-short-video-1',
  );
  @override
  bool supports(Uri uri) => true;
  @override
  Future<ParseResult> resolve(Uri uri, ToolboxCancellation cancellation) async {
    calls++;
    return ToolboxFixture.video;
  }

  @override
  void close() {}
}
