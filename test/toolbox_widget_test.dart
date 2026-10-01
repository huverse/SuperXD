import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/toolbox/download/download_status.dart';
import 'package:superxd/toolbox/download/downloads_page.dart';
import 'package:superxd/toolbox/short_video/parse_history_page.dart';
import 'package:superxd/toolbox/short_video/short_video_page.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/media_resource.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/short_video/media_result_page.dart';

import 'toolbox_test_support.dart';

Future<void> waitForWidget(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100 && finder.evaluate().isEmpty; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finder, findsOneWidget);
}

// 界面先于入队出现；等点击发起的入队在测试时钟里跑完再推送传输事件，避免锁被挂起的调度占住。
Future<void> waitUntil(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 100 && !done(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done(), isTrue);
}

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

  testWidgets('轻量工具直接可用，不显示虚假的资源下载安装', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: ToolboxPage(runtime: fixture.runtime),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('短视频去水印解析【聚合】'), findsOneWidget);
    expect(find.byTooltip('下载资源'), findsNothing);
    expect(find.byTooltip('管理资源'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('拒绝授权不解析，同意后解析与下载状态可见', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: ShortVideoPage(runtime: fixture.runtime),
      ),
    );
    await waitForWidget(tester, find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://v.douyin.com/example/',
    );
    await tester.pump();
    await tester.tap(find.text('解析'));
    await waitForWidget(tester, find.text('第三方解析'));
    await tester.pumpAndSettle();
    expect(find.text('第三方解析'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(fixture.parser.calls, 0);
    await tester.tap(find.text('解析'));
    await waitForWidget(tester, find.text('第三方解析'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并解析'));
    await tester.pump();
    await waitForWidget(tester, find.text('下载视频'));
    await tester.pumpAndSettle();
    expect(fixture.parser.calls, 1);
    expect(find.text('下载视频'), findsOneWidget);
    await tester.tap(find.text('下载视频'));
    await waitForWidget(tester, find.text('等待下载'));
    expect(find.text('下载视频'), findsNothing);
    expect(find.text('取消下载'), findsOneWidget);
    await tester.tap(find.byTooltip('下载管理'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await waitForWidget(tester, find.text('等待下载'));
    expect(find.text('取消下载'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('最近解析与历史点击直达结果页，命中缓存且不改保存的来源', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: ShortVideoPage(runtime: fixture.runtime),
      ),
    );
    await waitForWidget(tester, find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('最近解析'), findsNothing);
    await tester.enterText(
      find.byType(TextField),
      'https://v.douyin.com/example/',
    );
    await tester.pump();
    await tester.tap(find.text('解析'));
    await waitForWidget(tester, find.text('同意并解析'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意并解析'));
    await tester.pump();
    await waitForWidget(tester, find.text('下载视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await waitForWidget(tester, find.text('最近解析'));
    await tester.pumpAndSettle();
    expect(find.textContaining('视频 · BugPK · '), findsOneWidget);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('最近一次成功 · '), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合成视频'));
    await waitForWidget(tester, find.text('下载视频'));
    await tester.pumpAndSettle();
    expect(find.textContaining('最近缓存'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await waitForWidget(tester, find.text('全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部'));
    await waitForWidget(tester, find.byTooltip('删除此条'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合成视频'));
    await waitForWidget(tester, find.text('下载视频'));
    await tester.pumpAndSettle();
    expect(fixture.parser.calls, 1);
    String? saved;
    await tester.runAsync(
      () async =>
          saved = await fixture.store.preference('parse_source'),
    );
    expect(saved, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('解析历史逐条删除与清空后列表即时刷新，不误报失败', (tester) async {
    await tester.runAsync(() async {
      for (final name in ['甲', '乙']) {
        await fixture.store.addHistory(
          id: 'history_$name',
          sourceUrl: Uri.parse('https://example.com/$name'),
          providerId: 'bugpk',
          title: '合成历史$name',
          kind: 'video',
        );
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: ParseHistoryPage(
          store: fixture.store,
          providers: fixture.runtime.coordinator.providers,
        ),
      ),
    );
    await waitForWidget(tester, find.text('合成历史甲'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('合成历史甲'),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip('删除此条'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await waitUntil(tester, () => find.text('合成历史甲').evaluate().isEmpty);
    await tester.pumpAndSettle();
    expect(find.text('删除未完成，请重试'), findsNothing);
    expect(find.text('合成历史乙'), findsOneWidget);
    List<Map<String, Object?>> rows = const [];
    await tester.runAsync(() async => rows = await fixture.store.history());
    expect(rows.map((row) => row['title']), ['合成历史乙']);
    await tester.tap(find.byTooltip('清空历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await waitForWidget(tester, find.text('暂无解析历史'));
    await tester.pumpAndSettle();
    expect(find.text('删除未完成，请重试'), findsNothing);
    await tester.runAsync(() async => rows = await fixture.store.history());
    expect(rows, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('结果页下载进度原地刷新，保存完成后切换为打开', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: MediaResultPage(
          runtime: fixture.runtime,
          outcome: ParseOutcome(ToolboxFixture.video, attempts: const []),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('下载视频'));
    await waitForWidget(tester, find.text('等待下载'));
    await waitUntil(tester, () => fixture.transfer.enqueueCount == 1);
    final id = fixture.manager.forTool('short_video').single.id;
    await tester.runAsync(() async {
      fixture.transfer.send(
        ToolboxTransferUpdate(
          id,
          ToolboxDownloadState.downloading,
          progress: .42,
          totalBytes: 10 * 1048576,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('下载中'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('4.2 / 10.0 MB'), findsOneWidget);
    expect(find.text('暂停'), findsOneWidget);
    await tester.runAsync(() async {
      await fixture.finish(id, ToolboxFixture.mp4);
      await fixture.waitFor(id, ToolboxDownloadState.saved);
    });
    await tester.pump();
    expect(find.text('已保存到本地'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '打开'), findsOneWidget);
    expect(find.text('下载视频'), findsNothing);
    expect(find.text('预览'), findsNothing);
    await tester.tap(find.text('打开'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('下载管理页按序号稳定排列，整组操作收进菜单', (tester) async {
    final gallery = ParseResult(
      sourceUrl: Uri.parse('https://example.com/gallery'),
      providerId: 'bugpk',
      title: '合成图集',
      author: '',
      resources: List.generate(
        12,
        (index) => MediaResource(
          id: 'image_$index',
          kind: MediaKind.image,
          url: Uri.parse('https://cdn.example.com/$index.png'),
          label: '图片${index + 1}',
        ),
      ),
    );
    await tester.runAsync(() async {
      await fixture.manager.downloadMedia(
        title: gallery.title,
        identity: gallery.identity,
        sourceUrl: gallery.sourceUrl,
        providerId: gallery.providerId,
        media: gallery.resources,
      );
      final failed = fixture.manager
          .forTool('short_video')
          .firstWhere((item) => item.resourceId == 'image_10');
      fixture.transfer.send(
        ToolboxTransferUpdate(
          failed.id,
          ToolboxDownloadState.failed,
          error: '网络中断',
        ),
      );
      await fixture.waitFor(failed.id, ToolboxDownloadState.failed);
    });
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.4)),
          child: child!,
        ),
        home: DownloadsPage(runtime: fixture.runtime),
      ),
    );
    await tester.pump();
    expect(find.text('进行中 1'), findsOneWidget);
    expect(find.text('已保存 0/12 · 进行中 11 · 未完成 1'), findsOneWidget);
    expect(find.text('图片 1'), findsNothing);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('取消全部'), findsOneWidget);
    expect(find.text('删除记录'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('查看全部 12 项'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('图片 11'), 200);
    final row = tester.widget<DownloadProgress>(
      find.ancestor(
        of: find.text('图片 11'),
        matching: find.byType(DownloadProgress),
      ),
    );
    expect(row.item.resourceId, 'image_10');
    expect(find.text('网络中断'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('重新解析未完成项'), 200);
    expect(
      find.widgetWithText(FilledButton, '重新解析未完成项'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('右滑只是揭示卸载，取消确认保持安装', (tester) async {
    await tester.runAsync(() async {
      final id = await fixture.manager.downloadResource('large_tool');
      await fixture.finish(id, ToolboxFixture.resourceBytes);
      await fixture.waitFor(id, ToolboxDownloadState.installed);
    });
    final module = ToolboxModule(
      id: 'large_tool',
      name: '测试资源工具',
      icon: CampusIcons.toolbox,
      resource: ToolboxFixture.resource,
      builder: (_) => const SizedBox(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: ToolboxPage(runtime: fixture.runtime, modules: [module]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.text('测试资源工具'), const Offset(260, 0));
    await tester.pumpAndSettle();
    expect(fixture.resources.installed('large_tool'), isTrue);
    await tester.tap(find.text('卸载').first);
    await tester.pumpAndSettle();
    expect(find.text('卸载测试资源工具？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(fixture.resources.installed('large_tool'), isTrue);
    await tester.tap(find.byTooltip('管理资源'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '卸载'));
    await tester.pumpAndSettle();
    for (
      var tick = 0;
      tick < 20 && fixture.resources.installed('large_tool');
      tick++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(fixture.resources.installed('large_tool'), isFalse);
    expect(find.byTooltip('下载资源'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('五主题明暗和窄屏大字号无溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final brightness in Brightness.values) {
      for (final palette in CampusPalette.forBrightness(brightness)) {
        await tester.pumpWidget(
          MaterialApp(
            theme: campusTheme(palette: palette),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.4)),
              child: child!,
            ),
            home: ShortVideoPage(key: UniqueKey(), runtime: fixture.runtime),
          ),
        );
        await waitForWidget(tester, find.byType(TextField));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('图集结果大字号布局与逐张下载入口可见', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final result = ParseResult(
      sourceUrl: Uri.parse('https://example.com/gallery'),
      providerId: 'bugpk',
      title: '图集',
      author: '',
      resources: List.generate(
        3,
        (index) => MediaResource(
          id: 'image_$index',
          kind: MediaKind.image,
          url: Uri.parse('https://cdn.example.com/$index.png'),
          label: '图片${index + 1}',
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.4)),
          child: child!,
        ),
        home: MediaResultPage(
          runtime: fixture.runtime,
          outcome: ParseOutcome(result, attempts: const []),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('全部下载'), findsOneWidget);
    await tester.tap(find.text('全部下载'));
    await waitForWidget(tester, find.text('已保存 0/3 · 进行中 3'));
    await waitUntil(tester, () => fixture.transfer.enqueueCount == 2);
    expect(find.text('全部下载'), findsNothing);
    final failed = fixture.manager
        .forTool('short_video')
        .firstWhere((item) => item.resourceId == 'image_1');
    await tester.runAsync(() async {
      fixture.transfer.send(
        ToolboxTransferUpdate(failed.id, ToolboxDownloadState.failed),
      );
      await fixture.waitFor(failed.id, ToolboxDownloadState.failed);
    });
    await tester.pump();
    expect(find.text('已保存 0/3 · 进行中 2 · 未完成 1'), findsOneWidget);
    expect(find.text('下载其余1张'), findsOneWidget);
    await tester.scrollUntilVisible(find.byTooltip('重新下载第2张'), 200);
    expect(find.byTooltip('取消下载第1张'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('图集排队等导出显示中性等待，导出失败才给重试保存', (tester) async {
    final result = ParseResult(
      sourceUrl: Uri.parse('https://example.com/slow_gallery'),
      providerId: 'bugpk',
      title: '慢导出图集',
      author: '',
      resources: List.generate(
        2,
        (index) => MediaResource(
          id: 'image_$index',
          kind: MediaKind.image,
          url: Uri.parse('https://cdn.example.com/$index.png'),
          label: '图片${index + 1}',
        ),
      ),
    );
    const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: MediaResultPage(
          runtime: fixture.runtime,
          outcome: ParseOutcome(result, attempts: const []),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('全部下载'));
    await waitUntil(tester, () => fixture.transfer.enqueueCount == 2);
    final items = {
      for (final item in fixture.manager.forTool('short_video'))
        item.resourceId!: item.id,
    };
    await tester.runAsync(() async {
      // 闸门须在真实异步区创建：假时钟区建的 Completer 完成后要靠 pump 才传播，用例失败时 tearDown 放闸也传不出去。
      fixture.publisher.gate = Completer<void>();
      await fixture.finish(items['image_0']!, png);
      await fixture.waitFor(items['image_0']!, ToolboxDownloadState.saving);
      await fixture.finish(items['image_1']!, png);
      await fixture.waitFor(
        items['image_1']!,
        ToolboxDownloadState.awaitingSave,
      );
    });
    await tester.pump();
    await tester.scrollUntilVisible(find.byTooltip('取消下载第2张'), 200);
    expect(find.byTooltip('重试保存第2张'), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('取消下载第2张'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: DownloadsPage(runtime: fixture.runtime),
      ),
    );
    await tester.pump();
    expect(find.text('等待保存'), findsOneWidget);
    expect(find.text('重试保存'), findsNothing);
    expect(find.text('取消下载'), findsNothing);
    fixture.publisher.fail = true;
    fixture.publisher.gate!.complete();
    await waitUntil(
      tester,
      () => items.values.every((id) => fixture.manager.byId(id)!.saveFailed),
    );
    expect(find.text('待保存'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, '重试保存'), findsNWidgets(2));
    fixture.publisher.fail = false;
    await tester.tap(find.widgetWithText(FilledButton, '重试保存').first);
    await waitUntil(
      tester,
      () =>
          fixture.manager.byId(items['image_0']!)!.state ==
          ToolboxDownloadState.saved,
    );
    expect(find.widgetWithText(FilledButton, '重试保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('工具页导航实际打开轻量功能', (tester) async {
    final router = GoRouter(
      initialLocation: '/toolbox',
      routes: [
        GoRoute(
          path: '/toolbox',
          builder: (_, _) => ToolboxPage(runtime: fixture.runtime),
        ),
        GoRoute(
          path: '/toolbox/short_video',
          builder: (_, _) => ShortVideoPage(runtime: fixture.runtime),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(theme: campusTheme(), routerConfig: router),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('短视频去水印解析【聚合】'));
    await tester.pump();
    await waitForWidget(tester, find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('作品链接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });
}
