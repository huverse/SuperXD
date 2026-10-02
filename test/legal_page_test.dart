import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/page/legal_page.dart';
import 'package:superxd/theme/campus_theme.dart';

void main() {
  testWidgets('隐私说明覆盖HTTP与本地凭据，长文能滚到删除和反馈', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: campusTheme(), home: const LegalPage(privacy: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.textContaining('HTTP 明文'), findsOneWidget);
    expect(find.textContaining('交给你选择的日历应用'), findsOneWidget);
    expect(find.textContaining('桌面小组件把今天起7天的课程'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('删除与设备备份'),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('公共 Download/SuperXD'), findsOneWidget);
    expect(find.textContaining('只读取你选中的那一张图片'), findsOneWidget);
    expect(find.textContaining('课前提醒只按本机课表在系统中定时'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('反馈与更新'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('未来新增第三方解析来源'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Alpha说明窄屏大字深浅色可读，不是占位文本', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final theme in [ThemeData.light(), ThemeData.dark()]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: const LegalPage(privacy: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alpha 内测说明'), findsOneWidget);
      expect(find.textContaining('不是学校官方客户端'), findsOneWidget);
      expect(find.textContaining('待替换'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('未登录路由可以打开两个告知页面并返回', (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => context.push('/legal/service'),
                  child: const Text('查看内测说明'),
                ),
                TextButton(
                  onPressed: () => context.push('/legal/privacy'),
                  child: const Text('查看数据说明'),
                ),
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/legal/:kind',
          builder: (_, state) =>
              LegalPage(privacy: state.pathParameters['kind'] == 'privacy'),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(theme: campusTheme(), routerConfig: router),
    );
    await tester.pumpAndSettle();
    for (final label in ['查看内测说明', '查看数据说明']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.byType(LegalPage), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });

  test('Alpha版本、并装、默认开发与非debug发布配置一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(pubspec, contains('version: 1.0.0-alpha.1+2'));
    expect(pubspec, contains('default-flavor: production'));
    expect(gradle, contains('applicationIdSuffix = ".alpha"'));
    expect(gradle, contains('Release signing is required'));
    expect(
      gradle,
      isNot(contains('signingConfig = signingConfigs.getByName("debug")')),
    );
    expect(
      File('android/gradle.properties').readAsStringSync(),
      contains('force-version-code-ignoring-abi=true'),
    );
  });
}
