import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/local/legal_notice_memory.dart';
import 'package:superxd/page/legal_page.dart';
import 'package:superxd/theme/campus_theme.dart';

void main() {
  testWidgets('隐私政策先摘要再分节，末尾三份清单；覆盖教务明文、私信服务器数据、第三方 SDK、权限与用户权利，长文能滚到底', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: campusTheme(), home: const LegalPage(privacy: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.textContaining('更新日期'), findsOneWidget);
    expect(find.text('摘要'), findsOneWidget);
    expect(find.textContaining('开发者收不到'), findsOneWidget);
    expect(find.textContaining('HTTP 明文'), findsWidgets);
    final scrollable = find.byType(Scrollable).first;
    // 按文档顺序往下滚。
    for (final (title, fragment) in [
      ('二、私信', '按 IP 地址计数限流'),
      ('四、百宝箱：学习通签到', '打开位置签到时申请定位权限（仅使用期间）'),
      ('四、百宝箱：学习通签到', '本机不保存签到记录与群消息'),
      ('五、检查更新与安装', '只向开发者的自建中转服务器发送应用的构建渠道（如 Alpha）与处理器架构'),
      ('七、你的权利', '撤回同意'),
      ('八、未成年人', '未满 14 周岁'),
      ('九、政策更新与联系', '私下联系开发者：QQ 209320162，邮箱 vbhcchhvvvhh@gmail.com'),
      ('附录一 第三方 SDK 与服务', 'https://lbs.amap.com/pages/privacy/'),
      ('附录一 第三方 SDK 与服务', 'mobile_scanner'),
      ('附录一 第三方 SDK 与服务', 'com.hihonor.mcs:ads-identifier'),
      ('附录二 系统权限', '相机：扫码（加好友、课堂签到二维码、代签码）时识别在本机完成'),
      ('附录二 系统权限', '位置：打开学习通位置签到时申请'),
      ('附录三 保存期限', '课表编辑历史：每学期最多 100 版'),
    ]) {
      await tester.scrollUntilVisible(find.text(title), 300, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(find.textContaining(fragment), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('用户协议窄屏大字深浅色可读，写明非官方、开源许可、私信规范与应用更新', (tester) async {
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
      await tester.scrollUntilVisible(find.text('一、SuperXD 是什么'), 300, scrollable: scrollable);
      expect(find.textContaining('不是学校官方应用'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('二、开源许可'), 300, scrollable: scrollable);
      expect(find.textContaining('GNU GPL v3.0'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('四、私信使用规范'), 300, scrollable: scrollable);
      expect(find.textContaining('开发者无法查看'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('七、应用更新'), 300, scrollable: scrollable);
      expect(find.textContaining('可能要求先更新再继续使用'), findsOneWidget);
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

  test('协议的同意与已读记录：写进文件、重开还在，alpha.4 只记了已读的仍要同意，坏文件当没同意过', () async {
    final directory = await Directory.systemTemp.createTemp('legal_notice');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/legal_notice.json');
    final memory = await LegalNoticeMemory.open(file);
    expect(memory.agreedRevision, isNull);
    var agreed = false;
    unawaited(memory.agreed.then((_) => agreed = true));
    await memory.markAgreed(legalRevision);
    await Future<void>.delayed(Duration.zero);
    expect(agreed, isTrue);
    final reopened = await LegalNoticeMemory.open(file);
    expect((reopened.agreedRevision, reopened.seenRevision), (legalRevision, legalRevision));
    expect(File('${file.path}.tmp').existsSync(), isFalse);
    await file.writeAsString('{"seenRevision":$legalRevision}');
    final older = await LegalNoticeMemory.open(file);
    expect((older.agreedRevision, older.seenRevision), (null, legalRevision));
    older.check(legalRevision);
    expect(older.takePending(), (revision: legalRevision, consent: true));
    await file.writeAsString('{坏');
    expect((await LegalNoticeMemory.open(file)).agreedRevision, isNull);
  });

  test('Alpha版本、并装、默认开发与非debug发布配置一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(pubspec, contains('version: 1.0.0-alpha.4+5'));
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

  // 隐私政策写明记住账号的凭据、私信密钥与学习通密码不随系统备份与换机迁移：安全存储的每个命名空间（数据与密钥两份）都要在两份规则里排除。
  test('安全存储的每个命名空间都排除出系统备份与换机迁移', () {
    final namespaces = {
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart')))
        for (final match in RegExp(r"storageNamespace: '(\w+)'").allMatches(file.readAsStringSync())) match.group(1)!,
    };
    expect(namespaces, containsAll(['superxd_credentials', 'superxd_social', 'superxd_chaoxing', 'superxd_pdd']));
    final backup = File('android/app/src/main/res/xml/backup_rules.xml').readAsStringSync();
    final extraction = File('android/app/src/main/res/xml/data_extraction_rules.xml').readAsStringSync();
    for (final namespace in namespaces) {
      for (final prefs in ['$namespace.xml', 'FlutterSecureKeyStorage:$namespace.xml']) {
        final rule = '<exclude domain="sharedpref" path="$prefs" />';
        expect(backup, contains(rule), reason: 'backup_rules 漏了 $prefs');
        expect(rule.allMatches(extraction).length, 2, reason: 'data_extraction_rules 的云备份与换机迁移都要排除 $prefs');
      }
    }
  });

  // release 才开 R8，CI 不打 release 包；高德 jar 不带混淆规则，删改类名后一开地图就崩。
  test('release 混淆规则保住高德 SDK', () {
    final rules = File('android/app/proguard-rules.pro').readAsStringSync();
    for (final package in ['com.amap.api', 'com.autonavi', 'com.loc']) {
      expect(rules, contains('-keep class $package.** { *; }'));
    }
  });
}
