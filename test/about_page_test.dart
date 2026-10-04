import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:superxd/page/about_page.dart';
import 'package:superxd/page/legal_page.dart';
import 'package:superxd/page/third_party_page.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/third_party_licenses.dart';

void main() {
  final info = PackageInfo(appName: 'SuperXD Alpha', packageName: 'com.superxd.superxd.alpha', version: '1.0.0-alpha.2', buildNumber: '3');

  Future<List<Uri>> pumpAbout(WidgetTester tester, {bool opens = true}) async {
    final opened = <Uri>[];
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (context, state) => AboutPage(packageInfo: Future.value(info), openUrl: (url) async { opened.add(url); return opens; })),
      GoRoute(path: '/legal/:kind', builder: (context, state) => LegalPage(privacy: state.pathParameters['kind'] == 'privacy')),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(theme: campusTheme(), routerConfig: router));
    await tester.pumpAndSettle();
    return opened;
  }

  testWidgets('关于页显示版本，协议与政策可进可回，源代码与反馈交给浏览器', (tester) async {
    final opened = await pumpAbout(tester);
    expect(find.text('SuperXD Alpha'), findsOneWidget);
    expect(find.text('版本 1.0.0-alpha.2（3）'), findsOneWidget);
    expect(find.text('Powered&Design By Galaxyous'), findsOneWidget);
    for (final (label, title) in [('用户协议', '协议说明'), ('隐私政策', '概述')]) {
      await tester.tap(find.text(label)); await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      await tester.tap(find.byTooltip('返回')); await tester.pumpAndSettle();
      expect(find.byType(AboutPage), findsOneWidget);
    }
    await tester.tap(find.text('源代码')); await tester.pumpAndSettle();
    await tester.tap(find.text('反馈问题')); await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://github.com/huverse/SuperXD'), Uri.parse('https://github.com/huverse/SuperXD/issues')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有浏览器时原地提示链接，不静默失败', (tester) async {
    await pumpAbout(tester, opens: false);
    await tester.tap(find.text('源代码')); await tester.pumpAndSettle();
    expect(find.textContaining('没有可打开链接的浏览器'), findsOneWidget);
    expect(find.textContaining(sourceRepositoryUrl), findsOneWidget);
  });

  testWidgets('开源许可页列出本项目 GPL、第三方组件，并可进入全部依赖许可', (tester) async {
    await pumpAbout(tester);
    await tester.tap(find.text('开源许可')); await tester.pumpAndSettle();
    expect(find.byType(ThirdPartyPage), findsOneWidget);
    expect(find.textContaining('GNU General Public License v3.0'), findsOneWidget);
    expect(find.textContaining('Maple Mono NF CN'), findsOneWidget);
    expect(find.textContaining('math-curve-loaders'), findsOneWidget);
    // 不点进去：依赖许可页在假时钟里读 LicenseRegistry 不会结束，会拖住后面的用例；该页由 campus_glass_test 注入许可流单独测。
    expect(find.text('全部依赖许可'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('许可登记包含本项目 GPL 全文与两套字体许可', (tester) async {
    // 前面的用例在假时钟里读过声明文件，rootBundle 缓存的 Future 属于假时钟区，在真实异步区里等不到，先清缓存。
    rootBundle.clear();
    registerCampusLicenses();
    // 大于 50KB 的资源经 compute 读取，要在真实异步区里等。
    final entries = (await tester.runAsync(() => LicenseRegistry.licenses.toList()))!;
    String textOf(String package) => entries.where((entry) => entry.packages.contains(package)).expand((entry) => entry.paragraphs).map((paragraph) => paragraph.text).join('\n');
    expect(textOf('SuperXD'), contains('GNU GENERAL PUBLIC LICENSE'));
    expect(textOf('Maple Mono NF CN'), contains('SIL Open Font License'));
    expect(textOf('Noto Serif SC'), contains('SIL OPEN FONT LICENSE'));
    expect(textOf('SuperXD 第三方组件与改编来源'), contains('liquid_glass_widgets 1.8.1'));
  });
}
