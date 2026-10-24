import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    logs.environment = const {};
    var reads = 0;
    Future<Map<String, String>> environment() async {
      reads++;
      return const {'version': '1.0.0-alpha.6', 'device': 'Google Pixel 8'};
    }

    watchDeveloperMode(developer, logs, environment: environment);
    await tester.pump();
    expect((campusDiagnostics, logs.developer), (false, false));
    expect(records, isEmpty);
    // 关着时不读运行环境：普通用户启动不为它调系统接口。
    expect(reads, 0);

    await developer.setEnabled(true);
    await tester.pump();
    expect((campusDiagnostics, logs.developer), (true, true));
    expect(records, ['[App] action=diagnostics state=on', '[App] action=environment version=1.0.0-alpha.6 device=Google_Pixel_8']);
    await developer.setEnabled(false);
    expect((campusDiagnostics, logs.developer), (false, false));
    expect(records.last, '[App] action=diagnostics state=off version=1.0.0-alpha.6 device=Google_Pixel_8');
    // 再开不重读，开启记录里直接带上运行环境。
    await developer.setEnabled(true);
    await tester.pump();
    expect(records.last, '[App] action=diagnostics state=on version=1.0.0-alpha.6 device=Google_Pixel_8');
    expect(reads, 1);
    await developer.setEnabled(false);
  });

  testWidgets('开着开发者模式启动：读一次运行环境，记一条带运行环境的启动记录', (tester) async {
    final records = <String>[];
    final previous = campusLog;
    campusLog = records.add;
    addTearDown(() {
      campusLog = previous;
      campusDiagnostics = false;
    });
    final developer = DeveloperSettings.memory(enabled: true);
    watchDeveloperMode(developer, logs, environment: () async => const {'version': '1.0.0-alpha.6'});
    await tester.pump();
    expect(records, ['[App] action=start version=1.0.0-alpha.6']);
    expect(logs.environment, {'version': '1.0.0-alpha.6'});
    // 关掉，撤下卡顿统计的帧回调，不留给后面的用例。
    await developer.setEnabled(false);
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

    // 回到页顶再点开关：按步长往回滚只滚到刚露出就停，页面变长后停的位置可能压在顶栏下面。
    await tester.drag(scrollable, const Offset(0, 4000));
    await tester.pumpAndSettle();
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

  // 模拟器上发现：按钮贴边太近，一拖就成了系统的边缘返回手势，把应用退出了。
  testWidgets('悬浮按钮让开系统的边缘返回手势区；拖到左半边松手贴左边，同样在手势区以外', (tester) async {
    tester.view.systemGestureInsets = FakeViewPadding(left: 30 * tester.view.devicePixelRatio, right: 30 * tester.view.devicePixelRatio);
    addTearDown(tester.view.resetSystemGestureInsets);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      theme: campusTheme(),
      navigatorKey: navigator,
      builder: (context, child) => DeveloperOverlay(developer: DeveloperSettings.memory(enabled: true), logs: logs, navigator: navigator, location: () => '/today', child: child!),
      home: const Scaffold(),
    ));
    await tester.pump();
    final button = find.byTooltip('开发者工具');
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(tester.getRect(button).right, lessThanOrEqualTo(width - 30 - 8));
    // 同真机：一帧里会来好几个移动事件（以前每个事件都拿上一帧的位置加位移，按钮只跟上手指的几分之一，模拟器上拖不动）。
    final gesture = await tester.startGesture(tester.getCenter(button));
    for (var step = 0; step < 40; step++) {
      await gesture.moveBy(Offset(-width * .7 / 40, -2.5));
      if (step % 5 == 4) await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getCenter(button).dx, closeTo(width - 30 - 8 - 24 - width * .7, 2));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(button).left, greaterThanOrEqualTo(30 + 8));
    expect(tester.getRect(button).right, lessThan(width / 2));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('当前页面 /today'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  // 审查发现：落盘要几十毫秒，弹层退场时还算挂着，连点两下「标记这里」会走两遍、第二遍把底下的页面也关掉。
  testWidgets('连点两下「标记这里」只记一次，底下的页面不被关掉', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    // 同真机：标记进本机日志、立即落盘（真实文件读写，假时钟里两下点按都落在写完之前）。
    final records = <String>[];
    final previous = campusLog;
    logs.developer = true;
    campusLog = logs.tee(records.add);
    addTearDown(() => campusLog = previous);
    await tester.pumpWidget(MaterialApp(
      theme: campusTheme(),
      navigatorKey: navigator,
      builder: (context, child) => DeveloperOverlay(developer: DeveloperSettings.memory(enabled: true), logs: logs, navigator: navigator, location: () => '/mine', child: child!),
      home: const Scaffold(body: Text('首页')),
    ));
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('二级页')))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开发者工具'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记这里'));
    await tester.tap(find.text('标记这里'));
    await settle(tester, () => find.text('已标记').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('二级页'), findsOneWidget);
    expect(records.where((record) => record.startsWith('[Mark]')), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('错误记录按种类合并、写出现几次；复制摘要把运行环境与几种错误放进剪贴板', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    for (var index = 0; index < 3; index++) {
      logs.record('[RelayTransport] action=request code=TIMEOUT waited=${index}ms errorType=TimeoutException');
    }
    logs.record('[Sync] action=run errorType=StateError\n#0 main');
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: DeveloperLogPage(logs: logs)));
    await tester.pump();
    await tester.tap(find.text('错误'));
    await tester.pump();
    await settle(tester, () => find.textContaining('共 3 次').evaluate().isNotEmpty);
    expect(find.textContaining('[RelayTransport]'), findsOneWidget);
    expect(find.textContaining('[Sync]'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: DeveloperPage(developer: DeveloperSettings.memory(enabled: true), logs: logs)));
    await settle(tester, () => find.textContaining('本机共').evaluate().isNotEmpty);
    await tester.tap(find.text('复制摘要'));
    await tester.pump();
    await settle(tester, () => copied != null);
    expect(copied, allOf(contains('device: Google Pixel 8'), contains('最近的错误（共 2 种'), contains('waited=#ms errorType=TimeoutException × 3')));
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
