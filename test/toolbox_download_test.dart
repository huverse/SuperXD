import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/media_resource.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/download/toolbox_download_manager.dart';

import 'toolbox_test_support.dart';

void main() {
  late ToolboxFixture fixture;
  setUp(() async {
    fixture = ToolboxFixture();
    await fixture.initialize();
  });
  tearDown(() async {
    await fixture.close();
  });

  test('权限弹窗未结束时不暴露尚未入队的可取消任务', () async {
    fixture.transfer.notificationPermission = Completer<void>();
    final started = fixture.downloadVideo(ToolboxFixture.video);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fixture.manager.forTool('short_video'), isEmpty);
    expect(fixture.transfer.enqueueCount, 0);
    fixture.transfer.notificationPermission!.complete();
    final id = await started;
    expect(fixture.manager.byId(id)!.state, ToolboxDownloadState.queued);
  });

  test('入队中取消必须等待入队完成，不能取消后复活下载', () async {
    fixture.transfer.enqueueGate = Completer<void>();
    final starting = fixture.downloadVideo(ToolboxFixture.video);
    while (fixture.manager.forTool('short_video').isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final id = fixture.manager.forTool('short_video').single.id;
    final cancelling = fixture.manager.cancel(id);
    fixture.transfer.enqueueGate!.complete();
    await starting;
    await cancelling;
    expect(fixture.manager.byId(id)!.state, ToolboxDownloadState.cancelled);
    expect(fixture.transfer.records.containsKey(id), isFalse);
  });

  test('重复点击只入队一次，校验后成功发布才标已保存', () async {
    final ids = await Future.wait([
      fixture.downloadVideo(ToolboxFixture.video),
      fixture.downloadVideo(ToolboxFixture.video),
    ]);
    expect(ids[0], ids[1]);
    expect(fixture.transfer.enqueueCount, 1);
    await fixture.finish(ids[0], ToolboxFixture.mp4, mimeType: 'video/mp4');
    await fixture.waitFor(ids[0], ToolboxDownloadState.saved);
    expect(fixture.manager.byId(ids[0])!.savedUri, isNotNull);
    expect(fixture.manager.byId(ids[0])!.url, isNull);
    expect(
      await fixture.manager.file(fixture.manager.byId(ids[0])!).exists(),
      isFalse,
    );
  });

  test('HTML错误页不能伪装视频保存，错误任务清掉临时文件', () async {
    final id = await fixture.downloadVideo(ToolboxFixture.video);
    await fixture.finish(
      id,
      '<html>not a video</html>'.codeUnits,
      mimeType: 'text/html',
    );
    await fixture.waitFor(id, ToolboxDownloadState.failed);
    expect(fixture.publisher.calls, 0);
    expect(
      await fixture.manager.file(fixture.manager.byId(id)!).exists(),
      isFalse,
    );
  });

  test('保存失败保留私有源文件，不误报成功且可重试', () async {
    fixture.publisher.fail = true;
    final id = await fixture.downloadVideo(ToolboxFixture.video);
    await fixture.finish(id, ToolboxFixture.mp4);
    await fixture.waitFor(id, ToolboxDownloadState.awaitingSave);
    expect(
      await fixture.manager.file(fixture.manager.byId(id)!).exists(),
      isTrue,
    );
    fixture.publisher.fail = false;
    await fixture.manager.save(id);
    expect(fixture.manager.byId(id)!.state, ToolboxDownloadState.saved);
  });

  test('后台传输完成保持待保存，恢复前台后完成发布', () async {
    fixture.manager.foreground = false;
    final id = await fixture.downloadVideo(ToolboxFixture.video);
    await fixture.finish(id, ToolboxFixture.mp4);
    await fixture.waitFor(id, ToolboxDownloadState.awaitingSave);
    expect(fixture.publisher.calls, 0);
    expect(await fixture.downloadVideo(ToolboxFixture.video), id);
    await fixture.manager.resume();
    expect(fixture.manager.byId(id)!.state, ToolboxDownloadState.saved);
  });

  test('取消等待原生停止，迟到完成回调不会保存或重建任务', () async {
    final id = await fixture.downloadVideo(ToolboxFixture.video);
    await fixture.manager
        .file(fixture.manager.byId(id)!)
        .writeAsBytes(ToolboxFixture.mp4);
    fixture.transfer.cancellation = Completer<void>();
    final operation = fixture.manager.cancel(id);
    await fixture.waitFor(id, ToolboxDownloadState.cancelling);
    expect(
      await fixture.manager.file(fixture.manager.byId(id)!).exists(),
      isTrue,
    );
    fixture.transfer.send(
      ToolboxTransferUpdate(id, ToolboxDownloadState.verifying),
    );
    fixture.transfer.cancellation!.complete();
    await operation;
    await fixture.waitFor(id, ToolboxDownloadState.cancelled);
    expect(fixture.publisher.calls, 0);
    expect(
      await fixture.manager.file(fixture.manager.byId(id)!).exists(),
      isFalse,
    );
  });

  test('资源真实下载校验成功后才可用，卸载不删除已导出视频', () async {
    final videoId = await fixture.downloadVideo(ToolboxFixture.video);
    await fixture.finish(videoId, ToolboxFixture.mp4);
    await fixture.waitFor(videoId, ToolboxDownloadState.saved);
    final resourceId = await fixture.manager.downloadResource('large_tool');
    expect(fixture.resources.installed('large_tool'), isFalse);
    await fixture.finish(resourceId, ToolboxFixture.resourceBytes);
    await fixture.waitFor(resourceId, ToolboxDownloadState.installed);
    expect(fixture.resources.installed('large_tool'), isTrue);
    expect(
      await fixture.resources.file('large_tool').readAsBytes(),
      ToolboxFixture.resourceBytes,
    );
    await fixture.manager.uninstall('large_tool');
    expect(fixture.resources.installed('large_tool'), isFalse);
    expect(fixture.publisher.published.containsKey(videoId), isTrue);
    expect(fixture.manager.byId(videoId)!.state, ToolboxDownloadState.saved);
  });

  test('同大小错误hash资源拒绝安装并清理', () async {
    final id = await fixture.manager.downloadResource('large_tool');
    await fixture.finish(id, [5, 4, 3, 2, 1]);
    await fixture.waitFor(id, ToolboxDownloadState.failed);
    expect(fixture.resources.installed('large_tool'), isFalse);
    expect(
      await fixture.manager.file(fixture.manager.byId(id)!).exists(),
      isFalse,
    );
  });

  test('缺失或不完整资源在重启核对时不视为已安装', () async {
    await fixture.store.putResource('large_tool', ToolboxFixture.resource);
    await fixture.resources.restore();
    expect(fixture.resources.installed('large_tool'), isFalse);
    final target = fixture.resources.file('large_tool');
    await target.parent.create(recursive: true);
    await target.writeAsBytes([1]);
    await fixture.resources.restore();
    expect(fixture.resources.installed('large_tool'), isFalse);
  });

  test('任务容量有界，不积累无限未完成文件', () async {
    for (var index = 0; index < 10; index++) {
      await fixture.downloadVideo(
        ParseResult(
          sourceUrl: Uri.parse('https://example.com/$index'),
          providerId: 'bugpk',
          title: '',
          author: '',
          resources: [
            MediaResource(
              id: 'video',
              kind: MediaKind.video,
              url: Uri.parse('https://cdn.example.com/$index.mp4'),
              label: '视频',
            ),
          ],
        ),
      );
    }
    await expectLater(
      fixture.downloadVideo(ToolboxFixture.video),
      throwsA(isA<ToolboxException>()),
    );
    expect(fixture.transfer.enqueueCount, 2);
  });

  test('保存中崩溃重启按任务ID发布，已有公共文件不重复创建', () async {
    final now = DateTime.now().toUtc();
    final record = ToolboxDownload(
      id: 'recover',
      toolId: 'short_video',
      kind: ToolboxDownloadKind.video,
      filename: 'recover.part',
      createdAt: now,
      updatedAt: now,
      state: ToolboxDownloadState.saving,
      mimeType: 'video/mp4',
    );
    await fixture.store.putDownload(record);
    await fixture.manager.file(record).writeAsBytes(ToolboxFixture.mp4);
    fixture.publisher.published['recover'] = Uri.parse(
      'content://media/downloads/existing',
    );
    final restored = ToolboxDownloadManager(
      store: fixture.store,
      transfer: FakeTransfer(),
      publisher: fixture.publisher,
      directory: fixture.manager.directory,
      resources: fixture.resources,
    );
    await restored.initialize();
    expect(restored.byId('recover')!.state, ToolboxDownloadState.saved);
    expect(fixture.publisher.published, hasLength(1));
    await restored.close();
  });

  test('24小时未保存临时视频清理但已导出结果保留', () async {
    final old = DateTime.now().toUtc().subtract(const Duration(days: 2));
    final record = ToolboxDownload(
      id: 'old',
      toolId: 'short_video',
      kind: ToolboxDownloadKind.video,
      filename: 'old.part',
      createdAt: old,
      updatedAt: old,
      state: ToolboxDownloadState.awaitingSave,
      mimeType: 'video/mp4',
    );
    await fixture.store.putDownload(record);
    await File('${fixture.manager.directory.path}/old.part')
        .writeAsBytes(ToolboxFixture.mp4);
    final restored = ToolboxDownloadManager(
      store: fixture.store,
      transfer: FakeTransfer(),
      publisher: fixture.publisher,
      directory: fixture.manager.directory,
      resources: fixture.resources,
    )..foreground = false;
    await restored.initialize();
    expect(restored.byId('old')!.state, ToolboxDownloadState.cancelled);
    expect(
      await File('${fixture.manager.directory.path}/old.part').exists(),
      isFalse,
    );
    expect(fixture.publisher.calls, 0);
    await restored.close();
  });
}
