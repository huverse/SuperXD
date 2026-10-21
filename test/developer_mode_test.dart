import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/app_diagnostics.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/local/developer_settings.dart';
import 'package:superxd/local/diagnostic_log.dart';
import 'package:superxd/page/about_page.dart';
import 'package:superxd/page/developer_page.dart';
import 'package:superxd/theme/campus_theme.dart';

// 页面里读写日志是真实文件操作，假时钟里不会自己走完：交替让出真实事件循环与推一帧，直到条件满足。
Future<void> settle(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 200 && !done(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done(), isTrue);
}

void main() {
  final info = PackageInfo(appName: 'SuperXD Alpha', packageName: 'com.superxd.superxd.alpha', version: '1.0.0-alpha.6', buildNumber: '7');
  late Directory temp;
  late DiagnosticLog logs;
  late List<String> published;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('developer_mode_test');
    published = [];
    logs = await DiagnosticLog.open(
      directory: Directory(path.join(temp.path, 'logs')),
      exports: Directory(path.join(temp.path, 'cache')),
      publish: (archive, filename) async {
        published.add(filename);
        return true;
      },
    );
    logs.environment = {'version': '1.0.0-alpha.6', 'build': '7', 'device': 'Google Pixel 8'};
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> pumpAbout(WidgetTester tester, DeveloperSettings developer) async {
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => AboutPage(packageInfo: Future.value(info), developer: developer, logs: logs))]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(theme: campusTheme(), routerConfig: router));
    await tester.pumpAndSettle();
  }

  // 真机调试包发现：启动时开发者模式关着，接线照样去停没开过的卡顿统计，断言失败，main 后面的代码都没执行。
  testWidgets('开发者模式接线：关着启动不出错；开关切换时诊断记录、日志级别与开启记录跟着变', (tester) async {
    final records = <String>[];
    final previous = campusLog;
    campusLog = records.add;
    addTearDown(() {
      campusLog = previous;
      campusDiagnostics = false;
    });
    final developer = DeveloperSettings.memory();
    watchDeveloperMode(developer, logs, environment: Future.value(const {'version': '1.0.0-alpha.6', 'device': 'Google Pixel 8'}));
    await tester.pump();
    expect((campusDiagnostics, logs.developer), (false, false));
    expect(records, isEmpty);

    await developer.setEnabled(true);
    expect((campusDiagnostics, logs.developer), (true, true));
    expect(records.single, '[App] action=diagnostics state=on version=1.0.0-alpha.6 device=Google_Pixel_8');
    await developer.setEnabled(false);
    expect((campusDiagnostics, logs.developer), (false, false));
    expect(records.last, startsWith('[App] action=diagnostics state=off'));
  });

  testWidgets('关于页连点版本号 7 次开启开发者模式：第 4 次起提示还差几次，说明会记什么、确认了才开，开了多出开发者选项', (tester) async {
    final developer = DeveloperSettings.memory();
    await pumpAbout(tester, developer);
    expect(find.text('开发者选项'), findsNothing);
    final version = find.text('版本 1.0.0-alpha.6（7）');
    for (var tap = 1; tap <= 3; tap++) {
      await tester.tap(version);
      await tester.pump();
    }
    expect(find.textContaining('进入开发者模式'), findsNothing);
    await tester.tap(version);
    await tester.pump();
    expect(find.text('再点 3 次进入开发者模式'), findsOneWidget);
    for (var tap = 5; tap <= 7; tap++) {
      await tester.tap(version);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('开启开发者模式'), findsOneWidget);
    expect(find.textContaining('最多保留 7 天、20MB，不上传'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(developer.enabled, isFalse);

    for (var tap = 1; tap <= 7; tap++) {
      await tester.tap(version);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(developer.enabled, isTrue);
    expect(find.text('已开启开发者模式'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('开发者选项'), 100);
    expect(find.text('开发者选项'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('开发者选项：显示运行环境与连电脑命令；导出交给系统保存并提示文件名；清除要确认；关掉开发者模式删开发者模式日志、回到关于页', (tester) async {
    final developer = DeveloperSettings.memory(enabled: true);
    logs.developer = true;
    logs.record('[Route] action=change path=/today');
    logs.record('[App] action=uncaught errorType=StateError\n#0 main');
    await tester.runAsync(logs.flush);
    await pumpAbout(tester, developer);
    await tester.scrollUntilVisible(find.text('开发者选项'), 100);
    await tester.tap(find.text('开发者选项'));
    await tester.pumpAndSettle();
    expect(find.byType(DeveloperPage), findsOneWidget);
    final scrollable = find.descendant(of: find.byType(DeveloperPage), matching: find.byType(Scrollable)).first;
    await settle(tester, () => find.textContaining('本机共').evaluate().isNotEmpty);
    expect(find.textContaining('adb pull ${logs.directory.path}'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Google Pixel 8'), 100, scrollable: scrollable);
    expect(find.text('机型'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('导出日志'), -100, scrollable: scrollable);
    await tester.tap(find.text('导出日志'));
    await tester.pump();
    await settle(tester, () => published.isNotEmpty && find.textContaining('已保存到 Download/SuperXD').evaluate().isNotEmpty);
    expect(published.single, startsWith('SuperXD-日志-'));

    await tester.scrollUntilVisible(find.text('性能浮层'), 100, scrollable: scrollable);
    await tester.tap(find.text('性能浮层'));
    await tester.pump();
    expect(developer.performanceOverlay, isTrue);

    await tester.scrollUntilVisible(find.text('开发者模式'), -100, scrollable: scrollable);
    await tester.tap(find.text('开发者模式'));
    await tester.pumpAndSettle();
    expect(find.text('关闭开发者模式'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pump();
    await settle(tester, () => find.byType(DeveloperPage).evaluate().isEmpty);
    await tester.pumpAndSettle();
    expect(developer.enabled, isFalse);
    expect(developer.performanceOverlay, isFalse);
    final left = await tester.runAsync(() async => [for (final entity in logs.directory.listSync()) path.basename(entity.path)]);
    expect(left, ['errors.log']);
    expect(find.text('开发者选项'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('清除日志收在⋯里并要确认，确认后本机日志全删', (tester) async {
    logs.record('[App] action=uncaught errorType=StateError\n#0 main');
    await tester.runAsync(logs.flush);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: DeveloperPage(developer: DeveloperSettings.memory(enabled: true), logs: logs)));
    await settle(tester, () => find.textContaining('本机共').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除日志'));
    await tester.pumpAndSettle();
    expect(find.text('删除本机的全部日志，包括错误记录。'), findsOneWidget);
    await tester.tap(find.text('清除'));
    await tester.pump();
    await settle(tester, () => find.text('已清除日志').evaluate().isNotEmpty);
    expect(await tester.runAsync(() async => logs.directory.listSync()), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('查看日志：新的在上，可搜索，可切到错误记录；点开一条看全文与复制', (tester) async {
    logs.record('[Sync] action=run errorType=timeout\n#0      sync (file:///s.dart:3)');
    logs.developer = true;
    logs.record('[Route] action=change path=/today');
    logs.record('[Http] module=edu method=GET path=/x status=200 ms=12 bytes=34');
    await tester.runAsync(logs.flush);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: DeveloperLogPage(logs: logs)));
    await settle(tester, () => find.textContaining('[Http]').evaluate().isNotEmpty);
    expect(tester.getTopLeft(find.textContaining('[Http]')).dy, lessThan(tester.getTopLeft(find.textContaining('[Route]')).dy));

    await tester.enterText(find.byType(TextField), 'route');
    await tester.pump();
    expect(find.textContaining('[Http]'), findsNothing);
    expect(find.textContaining('[Route]'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    await tester.tap(find.text('错误'));
    await tester.pump();
    await settle(tester, () => find.textContaining('[Sync]').evaluate().isNotEmpty);
    expect(find.textContaining('[Route]'), findsNothing);
    await tester.tap(find.textContaining('[Sync]'));
    await tester.pump();
    expect(find.byTooltip('复制这条'), findsOneWidget);
    expect(find.textContaining('sync (file:///s.dart:3)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
