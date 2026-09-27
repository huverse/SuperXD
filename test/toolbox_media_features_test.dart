import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/toolbox/media_resource.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_store.dart';

import 'toolbox_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ToolboxFixture fixture;
  setUp(() async {
    fixture = ToolboxFixture();
    await fixture.initialize();
  });
  tearDown(() async {
    await fixture.close();
  });
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lN0AAAAASUVORK5CYII=',
  );
  List<MediaResource> images(int count) => List.generate(
    count,
    (index) => MediaResource(
      id: 'image_$index',
      kind: MediaKind.image,
      url: Uri.parse('https://cdn.example.com/$index.png'),
      label: '图片${index + 1}',
    ),
  );
  Future<List<String>> download(List<MediaResource> media) =>
      fixture.manager.downloadMedia(
        title: '合成图集',
        identity: 'gallery',
        sourceUrl: Uri.parse('https://example.com/gallery'),
        providerId: 'bugpk',
        media: media,
      );

  test('图集子项最多两项传输，完成后继续排队，部分失败重试不重复成功文件', () async {
    final ids = await download(images(3));
    expect(fixture.transfer.enqueueCount, 2);
    await fixture.finish(ids[0], png, mimeType: 'image/png');
    await fixture.waitFor(ids[0], ToolboxDownloadState.saved);
    expect(fixture.transfer.enqueueCount, 3);
    await fixture.finish(
      ids[1],
      '<html>expired</html>'.codeUnits,
      mimeType: 'text/html',
    );
    await fixture.waitFor(ids[1], ToolboxDownloadState.failed);
    await fixture.finish(ids[2], png, mimeType: 'image/png');
    await fixture.waitFor(ids[2], ToolboxDownloadState.saved);
    final retry = await download(images(3));
    expect(retry.where((id) => id == ids[0] || id == ids[2]), hasLength(2));
    expect(fixture.publisher.published, hasLength(2));
    expect(fixture.transfer.enqueueCount, 4);
  });
  test('暂停释放传输位，不能暂停时保留真实状态，继续不假报', () async {
    final id = await fixture.downloadVideo();
    fixture.transfer.canPause = false;
    await expectLater(
      fixture.manager.pauseTask(id),
      throwsA(isA<ToolboxException>()),
    );
    expect(fixture.manager.byId(id)!.state, ToolboxDownloadState.queued);
    fixture.transfer.canPause = true;
    await fixture.manager.pauseTask(id);
    expect(fixture.manager.byId(id)!.state, ToolboxDownloadState.paused);
    await fixture.manager.resumeTask(id);
    expect(fixture.manager.byId(id)!.state, ToolboxDownloadState.queued);
    await fixture.manager.cancel(id);
    expect(fixture.manager.byId(id)!.state, ToolboxDownloadState.cancelled);
  });
  test('删终态记录不删公共文件，迟到事件不能复活', () async {
    final id = await fixture.downloadVideo();
    await fixture.finish(id, ToolboxFixture.mp4);
    await fixture.waitFor(id, ToolboxDownloadState.saved);
    final group = fixture.manager.byId(id)!.jobId;
    await fixture.manager.deleteJob(group);
    fixture.transfer.send(
      ToolboxTransferUpdate(id, ToolboxDownloadState.downloading, progress: .5),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fixture.manager.byId(id), isNull);
    expect(fixture.publisher.published.containsKey(id), isTrue);
  });
  test('整组取消保留已保存项，未提交队列也停止', () async {
    final ids = await download(images(4));
    await fixture.finish(ids[0], png);
    await fixture.waitFor(ids[0], ToolboxDownloadState.saved);
    await fixture.manager.cancelJob(fixture.manager.byId(ids[0])!.jobId);
    expect(fixture.manager.byId(ids[0])!.state, ToolboxDownloadState.saved);
    expect(
      ids
          .skip(1)
          .every(
            (id) =>
                fixture.manager.byId(id)!.state ==
                ToolboxDownloadState.cancelled,
          ),
      isTrue,
    );
  });
  test('历史默认关闭、开启有界、关闭不新增、删除不影响下载', () async {
    Future<void> add(int index) => fixture.store.addHistory(
      id: '$index',
      sourceUrl: Uri.parse('https://example.com/$index'),
      providerId: 'bugpk',
      title: 'test',
      kind: 'video',
    );
    await add(0);
    expect(await fixture.store.history(), isEmpty);
    await fixture.store.setPreference('history_enabled', 'true');
    for (var index = 0; index < 85; index++) {
      await add(index);
    }
    expect(await fixture.store.history(), hasLength(80));
    await fixture.store.setPreference('history_enabled', 'false');
    await add(100);
    expect(
      (await fixture.store.history()).any((row) => row['id'] == '100'),
      isFalse,
    );
    final id = await fixture.downloadVideo();
    await fixture.store.clearHistory();
    expect(fixture.manager.byId(id), isNotNull);
  });
  test('v1升级仅迁移BugPK同意且保留下载记录', () async {
    final oldPath = path.join(fixture.directory.path, 'old.db');
    final old = await openDatabase(
      oldPath,
      version: 1,
      onCreate: (database, _) async {
        await database.execute(
          'CREATE TABLE downloads (id TEXT PRIMARY KEY, tool_id TEXT NOT NULL, terminal INTEGER NOT NULL, updated_at INTEGER NOT NULL, payload TEXT NOT NULL)',
        );
        await database.execute(
          'CREATE TABLE consent (service TEXT PRIMARY KEY, version TEXT NOT NULL)',
        );
        await database.execute(
          'CREATE TABLE resources (tool_id TEXT PRIMARY KEY, version TEXT NOT NULL, hash TEXT NOT NULL, bytes INTEGER NOT NULL)',
        );
        await database.insert('consent', {
          'service': 'short_video',
          'version': 'bugpk-short-video-1',
        });
      },
    );
    final now = DateTime.now().toUtc();
    final retained = ToolboxDownload(
      id: 'retained',
      toolId: 'short_video',
      kind: ToolboxDownloadKind.video,
      filename: 'retained.part',
      createdAt: now,
      updatedAt: now,
      state: ToolboxDownloadState.saved,
      savedUri: Uri.parse('content://media/downloads/1'),
      mimeType: 'video/mp4',
    );
    await old.insert('downloads', {
      'id': retained.id,
      'tool_id': retained.toolId,
      'terminal': 1,
      'updated_at': now.millisecondsSinceEpoch,
      'payload': jsonEncode(retained.toJson()),
    });
    await old.close();
    final migrated = await ToolboxStore.open(oldPath);
    expect(await migrated.consent('bugpk', 'bugpk-short-video-1'), isTrue);
    expect(await migrated.consent('other', 'bugpk-short-video-1'), isFalse);
    expect(await migrated.preference('history_enabled'), isNull);
    expect((await migrated.downloads()).single.savedUri, retained.savedUri);
    await migrated.close();
    expect(await File(oldPath).exists(), isTrue);
  });
}
