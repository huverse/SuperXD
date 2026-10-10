import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/share_card.dart';
import 'package:superxd/toolbox/short_video/media_resource.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/short_video/short_video_page.dart';
import 'package:superxd/toolbox/short_video/short_video_service.dart';
import 'package:superxd/toolbox/short_video/short_video_store.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
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
      fixture.shortVideo.download(
        ParseResult(sourceUrl: Uri.parse('https://example.com/gallery'), providerId: 'bugpk', title: '合成图集', author: '', resources: media),
        media,
      );

  test('图集子项最多两项传输，完成后继续排队，部分失败重试不重复成功文件', () async {
    final ids = await download(images(3));
    expect(fixture.transfer.enqueueCount, 2);
    await fixture.finish(ids[0], png, mimeType: 'image/png');
    await fixture.waitFor(ids[0], ToolboxDownloadState.saved);
    await fixture.waitForEnqueued(3);
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
  test('历史默认开启、有界、手动关闭不新增、删除不影响下载', () async {
    Future<void> add(int index) => fixture.shortVideo.store.addHistory(
      id: '$index',
      sourceUrl: Uri.parse('https://example.com/$index'),
      providerId: 'bugpk',
      title: 'test',
      kind: 'video',
    );
    expect(await fixture.shortVideo.store.preference('history_enabled'), isNull);
    await add(0);
    expect(await fixture.shortVideo.store.history(), hasLength(1));
    for (var index = 0; index < 85; index++) {
      await add(index);
    }
    expect(await fixture.shortVideo.store.history(), hasLength(80));
    await fixture.shortVideo.store.setPreference('history_enabled', 'false');
    await add(100);
    expect(
      (await fixture.shortVideo.store.history()).any((row) => row['id'] == '100'),
      isFalse,
    );
    final id = await fixture.downloadVideo();
    await fixture.shortVideo.store.clearHistory();
    expect(fixture.manager.byId(id), isNotNull);
  });
  test('短视频的历史与偏好从框架库搬到自己的库：搬完删旧表，重开不重复，已有的不被旧值覆盖', () async {
    // 老版本（框架库 v2）里的两张表与几行数据。
    final legacyPath = path.join(fixture.directory.path, 'legacy_toolbox.db');
    final legacy = await openDatabase(
      legacyPath,
      version: 2,
      onCreate: (database, _) async {
        await database.execute('CREATE TABLE downloads (id TEXT PRIMARY KEY, tool_id TEXT NOT NULL, terminal INTEGER NOT NULL, updated_at INTEGER NOT NULL, payload TEXT NOT NULL)');
        await database.execute('CREATE TABLE consent (service TEXT PRIMARY KEY, version TEXT NOT NULL)');
        await database.execute('CREATE TABLE resources (tool_id TEXT PRIMARY KEY, version TEXT NOT NULL, hash TEXT NOT NULL, bytes INTEGER NOT NULL)');
        await database.execute('CREATE TABLE toolbox_preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        await database.execute(
          'CREATE TABLE parse_history (id TEXT PRIMARY KEY, source_url TEXT NOT NULL, provider_id TEXT NOT NULL, title TEXT NOT NULL, kind TEXT NOT NULL, created_at INTEGER NOT NULL)',
        );
        await database.execute('CREATE INDEX parse_history_time ON parse_history (created_at DESC, id DESC)');
        await database.insert('toolbox_preferences', {'key': 'history_enabled', 'value': 'false'});
        await database.insert('toolbox_preferences', {'key': 'parse_source', 'value': 'bugpk'});
        await database.insert('parse_history', {
          'id': 'old',
          'source_url': 'https://example.com/old',
          'provider_id': 'bugpk',
          'title': '旧历史',
          'kind': 'video',
          'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        });
      },
    );
    await legacy.close();
    final toolbox = await ToolboxStore.open(legacyPath);
    final ownPath = path.join(fixture.directory.path, 'own_short_video.db');
    // 新库里已经有的值不被旧值覆盖（搬运中途失败重搬时也一样）。
    final seeded = await ShortVideoStore.open(ownPath, legacy: await ToolboxStore.open(path.join(fixture.directory.path, 'empty.db')));
    await seeded.setPreference('parse_source', 'auto');
    await seeded.close();

    final own = await ShortVideoStore.open(ownPath, legacy: toolbox);
    expect(await own.preference('history_enabled'), 'false');
    expect(await own.preference('parse_source'), 'auto');
    expect([for (final row in await own.history()) row['title']], ['旧历史']);
    expect(await toolbox.legacyShortVideoData(), isNull, reason: '搬完后框架库里不再有这两张表');
    await own.close();

    // 再开一次：没有旧表可搬，数据原样。
    final again = await ShortVideoStore.open(ownPath, legacy: toolbox);
    expect(await again.history(), hasLength(1));
    await again.close();
    await toolbox.close();
  });

  test('下载记录兼容旧格式：顶层的作品链接与来源搬进 origin，新记录按 origin 存取', () {
    final now = DateTime.now().toUtc();
    final legacy = ToolboxDownload.fromJson({
      'id': 'old',
      'toolId': 'short_video',
      'kind': 'video',
      'filename': 'old.part',
      'createdAt': now.toIso8601String(),
      'updatedAt': now.toIso8601String(),
      'state': 'failed',
      'title': '旧任务',
      'progress': 0,
      'totalBytes': -1,
      'sourceUrl': 'https://example.com/work',
      'providerId': 'bugpk',
    });
    expect(legacy.origin, {ShortVideoService.originSourceUrl: 'https://example.com/work', ShortVideoService.originProviderId: 'bugpk'});
    final roundTrip = ToolboxDownload.fromJson(jsonDecode(jsonEncode(legacy.toJson())) as Map<String, dynamic>);
    expect(roundTrip.origin, legacy.origin);
    expect(legacy.toJson().containsKey('sourceUrl'), isFalse);
  });

  test('按工具清空下载：取消进行中的、删掉本工具的记录，别的工具与已导出的文件不动', () async {
    final running = await fixture.downloadVideo();
    final other = (await fixture.manager.enqueue(
      toolId: 'other_tool',
      title: '别的工具',
      identity: 'other',
      items: [ToolboxDownloadRequest(id: 'file', url: Uri.parse('https://cdn.example.com/other.mp4'), kind: ToolboxDownloadKind.video)],
    )).single;
    await fixture.manager.clearTool(ShortVideoService.serviceId);
    expect(fixture.manager.byId(running), isNull);
    expect(fixture.manager.forTool(ShortVideoService.serviceId), isEmpty);
    expect(fixture.manager.byId(other), isNotNull);
    expect((await fixture.store.downloads()).map((item) => item.id), [other]);
  });

  test('短视频清除数据：下载记录、历史与偏好、各来源同意都清掉，下次打开是一份空的服务', () async {
    await fixture.downloadVideo();
    await fixture.shortVideo.store.addHistory(id: 'h', sourceUrl: Uri.parse('https://example.com/h'), providerId: 'bugpk', title: '历史', kind: 'video');
    await fixture.shortVideo.store.setPreference('parse_source', 'bugpk');
    await fixture.store.grantConsent('bugpk', 'bugpk-short-video-1');
    await fixture.store.grantConsent('chaoxing', 'chaoxing-sign-2');
    final database = File(path.join(fixture.directory.path, 'short_video.db'));
    expect(database.existsSync(), isTrue);

    await fixture.runtime.clearData(ShortVideoService.serviceId);
    expect(fixture.manager.forTool(ShortVideoService.serviceId), isEmpty);
    expect(await fixture.store.consent('bugpk', 'bugpk-short-video-1'), isFalse);
    expect(await fixture.store.consent('chaoxing', 'chaoxing-sign-2'), isTrue, reason: '只撤本工具来源的同意');
    expect(database.existsSync(), isFalse);
  });

  test('有本机数据的工具都写明清除数据会删什么（确认里不用一句通用话）', () {
    for (final module in toolboxCatalog(fixture.runtime).where((module) => module.openService != null)) {
      expect(module.clearedData, isNotEmpty, reason: module.id);
    }
  });

  test('好友分享的卡片按注册表找工具打开：短视频认视频卡，别的卡没人认', () {
    final modules = toolboxCatalog(fixture.runtime);
    Widget? open(ShareCard card) => modules.map((tool) => tool.openShared?.call(card)).nonNulls.firstOrNull;
    final page = open(const VideoShare(sourceUrl: 'https://v.example.com/1', title: '作品', author: '', platform: 'douyin', kind: 'video'));
    expect(page, isA<ShortVideoPage>());
    expect((page! as ShortVideoPage).initialInput, 'https://v.example.com/1');
    expect((page as ShortVideoPage).autoParse, isTrue);
    expect(open(const UnknownShare(type: 'future', version: 9)), isNull);
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
    expect((await migrated.legacyShortVideoData())?.preferences ?? const [], isEmpty);
    expect((await migrated.downloads()).single.savedUri, retained.savedUri);
    await migrated.close();
    expect(await File(oldPath).exists(), isTrue);
  });
}
