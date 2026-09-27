import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
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
    await waitForWidget(tester, find.text('已加入下载，共1项'));
    await tester.tap(find.byTooltip('下载管理'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await waitForWidget(tester, find.text('视频 · 等待下载'));
    expect(find.text('取消'), findsOneWidget);
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
