import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:superxd/domain/app_update.dart';
import 'package:superxd/page/about_page.dart';
import 'package:superxd/page/app_update_dialog.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'app_update_fakes.dart';

void main() {
  Future<List<Uri>> openDialog(WidgetTester tester, UpdateFixture fixture) async {
    final opened = <Uri>[];
    await tester.pumpWidget(MaterialApp(
      theme: campusTheme(),
      home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(
        onPressed: () => showAppUpdateDialog(context, fixture.updates, openUrl: (url) async {
          opened.add(url);
          return true;
        }),
        child: const Text('打开'),
      )))),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return opened;
  }

  testWidgets('可选更新：版本、大小与说明，更新在最上，跳过这个版本记下并关闭', (tester) async {
    final fixture = UpdateFixture()..feed.next = fakeRelease();
    await fixture.updates.check();
    await openDialog(tester, fixture);
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('版本 1.0.0-alpha.5 · 安装包 120 MB'), findsOneWidget);
    expect(find.text('修了一些问题'), findsOneWidget);
    // 三个按钮竖排，主操作在最上、跳过在最下。
    final update = tester.getCenter(find.text('更新')).dy, later = tester.getCenter(find.text('稍后')).dy, skip = tester.getCenter(find.text('跳过这个版本')).dy;
    expect(update < later && later < skip, isTrue);
    await tester.tap(find.text('跳过这个版本'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
    expect(fixture.memory.skippedVersionCode, 5);
  });

  testWidgets('点更新后进度在弹窗里原地显示，可后台下载收起，下完交给系统安装', (tester) async {
    final fixture = UpdateFixture()..feed.next = fakeRelease();
    await fixture.updates.check();
    await openDialog(tester, fixture);
    fixture.files.gate = Completer<void>();
    await tester.tap(find.text('更新'));
    await tester.pump();
    expect(find.text('正在下载 50%'), findsOneWidget);
    expect(find.text('60.0 / 120.0 MB'), findsOneWidget);
    expect(find.text('取消下载'), findsOneWidget);
    await tester.tap(find.text('后台下载'));
    await tester.pumpAndSettle();
    expect(find.text('正在下载 50%'), findsNothing);
    fixture.files.gate!.complete();
    await tester.pumpAndSettle();
    expect(fixture.installer.installs, ['/cache/app_update/SuperXD-5.apk']);
    // 再打开：停在可再点「安装」的状态（用户关掉过系统安装界面时用）。
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('安装包已核对，按系统提示完成安装'), findsOneWidget);
    await tester.tap(find.text('安装'));
    await tester.pumpAndSettle();
    expect(fixture.installer.installs, hasLength(2));
  });

  testWidgets('必须更新：标题直说，点遮罩与返回键都关不掉，没有稍后与跳过', (tester) async {
    final fixture = UpdateFixture()..feed.next = fakeRelease(minSupported: 5);
    await fixture.updates.check();
    await openDialog(tester, fixture);
    expect(find.text('需要更新'), findsOneWidget);
    expect(find.text('版本 1.0.0-alpha.5 · 安装包 120 MB\n当前版本已停用，更新后才能使用'), findsOneWidget);
    expect(find.text('稍后'), findsNothing);
    expect(find.text('跳过这个版本'), findsNothing);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('需要更新'), findsOneWidget);
  });

  testWidgets('下载失败给原因，可重试或用浏览器打开发布页', (tester) async {
    final fixture = UpdateFixture()..feed.next = fakeRelease();
    await fixture.updates.check();
    final opened = await openDialog(tester, fixture);
    fixture.files.downloadedSha = 'b' * 64;
    await tester.tap(find.text('更新'));
    await tester.pumpAndSettle();
    expect(find.text('安装包没下完整，请重试'), findsOneWidget);
    await tester.tap(find.text('浏览器下载'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://github.com/huverse/SuperXD/releases/tag/v1.0.0-alpha.5')]);
    fixture.files.downloadedSha = fakeSha;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('安装包已核对，按系统提示完成安装'), findsOneWidget);
  });

  testWidgets('没有安装授权：说明要开启，点去开启打开系统设置', (tester) async {
    final fixture = UpdateFixture()..feed.next = fakeRelease();
    fixture.installer.allowed = false;
    await fixture.updates.check();
    await openDialog(tester, fixture);
    await tester.tap(find.text('更新'));
    await tester.pumpAndSettle();
    expect(find.text('要先允许 SuperXD 安装应用，开启后返回会接着安装'), findsOneWidget);
    await tester.tap(find.text('去开启'));
    await tester.pumpAndSettle();
    expect(fixture.installer.settingsOpened, 1);
  });

  testWidgets('没有这个架构的安装包：只给去发布页下载', (tester) async {
    final fixture = UpdateFixture()..feed.next = fakeRelease(withApk: false);
    await fixture.updates.check();
    final opened = await openDialog(tester, fixture);
    expect(find.text('更新'), findsNothing);
    await tester.tap(find.text('去发布页下载'));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
  });

  testWidgets('关于页检查更新：已是最新写在行尾，查到新版弹窗，查不到给原因', (tester) async {
    final fixture = UpdateFixture();
    await tester.pumpWidget(MaterialApp(
      theme: campusTheme(),
      home: AboutPage(
        packageInfo: Future.value(PackageInfo(appName: 'SuperXD Alpha', packageName: 'com.superxd.superxd.alpha', version: '1.0.0-alpha.4', buildNumber: '4')),
        updates: fixture.updates,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('已是最新版本'), findsOneWidget);
    fixture.feed.error = const AppUpdateException('连不上更新服务器，请检查网络后再试');
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('连不上更新服务器，请检查网络后再试'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('检查失败'), findsOneWidget);
    fixture.feed
      ..error = null
      ..next = fakeRelease();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(find.text('新版本 1.0.0-alpha.5'), findsOneWidget);
  });
}
