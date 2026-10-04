import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/page/legal_page.dart';
import 'package:superxd/theme/campus_theme.dart';

void main() {
  testWidgets('隐私政策覆盖教务明文、私信服务器数据、相机权限与用户权利，长文能滚到联系方式', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: campusTheme(), home: const LegalPage(privacy: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.textContaining('更新日期'), findsOneWidget);
    expect(find.textContaining('开发者收不到'), findsOneWidget);
    expect(find.textContaining('HTTP 明文'), findsWidgets);
    final scrollable = find.byType(Scrollable).first;
    for (final (title, fragment) in [
      ('好友与私信', '按 IP 地址计数限流'),
      ('系统权限', '相机：只在扫码加好友时使用'),
      ('你的权利', '你可以撤回同意'),
      ('未成年人', '未满 14 周岁'),
      ('政策更新与联系', 'github.com/huverse/SuperXD/issues'),
    ]) {
      await tester.scrollUntilVisible(find.text(title), 300, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(find.textContaining(fragment), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('用户协议窄屏大字深浅色可读，写明非官方、开源许可与私信规范', (tester) async {
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
      expect(find.text('用户协议'), findsOneWidget);
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('SuperXD 是什么'), 300, scrollable: scrollable);
      expect(find.textContaining('不是学校官方应用'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('开源许可'), 300, scrollable: scrollable);
      expect(find.textContaining('GNU GPL v3.0'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('私信使用规范'), 300, scrollable: scrollable);
      expect(find.textContaining('开发者无法查看'), findsOneWidget);
      expect(find.textContaining('待替换'), findsNothing);
      expect(tester.takeException(), isNull);
      // 换主题前卸载，否则复用的列表停在上一轮的滚动位置。
      await tester.pumpWidget(const SizedBox());
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
    expect(pubspec, contains('version: 1.0.0-alpha.2+3'));
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
