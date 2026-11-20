import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/local/legal_notice_memory.dart';
import 'package:superxd/page/legal_page.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/social/social_spaces.dart';

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
      // 11-15 应用账号改为自己的账号体系（人工决策见 domain/app_account.dart）：服务器只存哈希、不提供人工找回，都要写明。
      ('一、教务账号、课表与成绩', '服务器只保存用它们算出的不可逆哈希'),
      ('一、教务账号、课表与成绩', '开发者不提供人工找回'),
      ('二、私信', '按 IP 地址计数限流'),
      // 11-14 私信跟着应用账号（人工决策见 social/social_service.dart）：服务器能看出账号之间的好友关系、换手机时公钥由服务器转交，都要写明。
      ('二、私信', '因此服务器知道哪些应用账号互为好友'),
      ('二、私信', '新手机的好友名单和好友的公钥由服务器给出'),
      ('四、百宝箱：学习通签到', '打开位置签到时申请定位权限（仅使用期间）'),
      ('四、百宝箱：学习通签到', '当前位置不发给高德'),
      ('四、百宝箱：学习通签到', '本机不保存签到记录与群消息'),
      ('五、百宝箱：快递（拼多多）', '会让你其他设备上的拼多多下线'),
      ('五、百宝箱：快递（拼多多）', '身份码是取件凭证，不写入文件，也不进日志'),
      // 11-20 电影院（人工决策见 lib/page/legal_page.dart 的 11-20 12:15:42 那条）：片名与播放页地址同意后才发给第三方，视频不经开发者的服务器。
      ('六、百宝箱：电影院', '你同意后才把你输入的片名直接发给这些站点'),
      ('六、百宝箱：电影院', '视频本身由播放器直接从第三方服务器取，不经开发者的服务器'),
      ('七、检查更新、开发者的话与安装', '只向开发者的自建中转服务器发送应用的构建渠道（如 Alpha）与处理器架构'),
      ('七、检查更新、开发者的话与安装', '获取开发者写的「开发者的话」，请求不附带任何信息'),
      ('八、节日活动与抽奖', '参加抽奖要登录应用账号'),
      ('八、节日活动与抽奖', '应用账号要建立满 7 天'),
      ('八、节日活动与抽奖', '同一个应用账号同一次活动只抽一次，换手机、重装后重新登录都不能再抽'),
      ('八、节日活动与抽奖', '注销应用账号不提前删除'),
      ('九、本机存储、备份与日志', '另在本机留一份约 1MB 的错误记录'),
      ('九、本机存储、备份与日志', '最多保留 7 天、20MB，关闭开发者模式即删除'),
      ('九、本机存储、备份与日志', '不会自动上传，只在你点「导出日志」时打包保存到 Download/SuperXD'),
      ('九、本机存储、备份与日志', '只有你点了并在确认框里确认后才发送，每次都要确认，从不自动上传'),
      ('九、本机存储、备份与日志', '服务器保存 30 天后自动删除；上传成功会给你一个诊断编号，要提前删除，凭编号按第十二节联系开发者'),
      ('十、你的权利', '撤回同意'),
      ('十一、未成年人', '未满 14 周岁'),
      ('十二、政策更新与联系', '私下联系开发者：QQ 209320162，邮箱 vbhcchhvvvhh@gmail.com'),
      ('附录一 第三方 SDK 与服务', 'https://lbs.amap.com/pages/privacy/'),
      ('附录一 第三方 SDK 与服务', '当前位置由手机系统定位提供、不经高德'),
      ('附录一 第三方 SDK 与服务', 'zxing-cpp 条码识别（开源，经插件 flutter_zxing 集成）'),
      ('附录一 第三方 SDK 与服务', '识别在本机完成、不联网'),
      ('附录一 第三方 SDK 与服务', 'com.hihonor.mcs:ads-identifier'),
      ('附录一 第三方 SDK 与服务', '拼多多（pinduoduo.com、yangkeduo.com'),
      ('附录二 系统权限', '相机：扫码（加好友、课堂签到二维码、代签码）时识别在本机完成'),
      ('附录二 系统权限', '位置：打开学习通位置签到时申请'),
      ('附录三 保存期限', '课表编辑历史：每学期最多 100 版'),
      ('附录三 保存期限', '开发者模式日志最多 7 天、20MB'),
      ('附录三 保存期限', '诊断包：你确认上传的加密日志包，30 天后删除'),
    ]) {
      await tester.scrollUntilVisible(find.text(title), 300, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(find.textContaining(fragment), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('用户协议窄屏大字深浅色可读，写明非官方、开源许可、私信规范、快递与应用更新', (tester) async {
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
      await tester.scrollUntilVisible(find.text('五、百宝箱与作品版权'), 300, scrollable: scrollable);
      expect(find.textContaining('开发者不提供、不存放任何影视内容'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('七、快递'), 300, scrollable: scrollable);
      expect(find.textContaining('遵守拼多多的服务条款'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('八、应用更新'), 300, scrollable: scrollable);
      expect(find.textContaining('可能要求先更新再继续使用'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('九、节日活动与奖励'), 300, scrollable: scrollable);
      expect(find.textContaining('不是商业抽奖'), findsOneWidget);
      expect(find.textContaining('每个应用账号每次活动只能抽一次'), findsOneWidget);
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
    expect(pubspec, contains('version: 1.0.0-alpha.33+33'));
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
  test('安全存储的每个命名空间与本机日志都排除出系统备份与换机迁移', () {
    final namespaces = {
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart')))
        for (final match in RegExp(r"storageNamespace: '(\w+)'").allMatches(file.readAsStringSync())) match.group(1)!,
    };
    expect(namespaces, containsAll(['superxd_credentials', 'superxd_social', 'superxd_chaoxing', 'superxd_pdd', 'superxd_account']));
    final backup = File('android/app/src/main/res/xml/backup_rules.xml').readAsStringSync();
    final extraction = File('android/app/src/main/res/xml/data_extraction_rules.xml').readAsStringSync();
    for (final namespace in namespaces) {
      for (final prefs in ['$namespace.xml', 'FlutterSecureKeyStorage:$namespace.xml']) {
        final rule = '<exclude domain="sharedpref" path="$prefs" />';
        expect(backup, contains(rule), reason: 'backup_rules 漏了 $prefs');
        expect(rule.allMatches(extraction).length, 2, reason: 'data_extraction_rules 的云备份与换机迁移都要排除 $prefs');
      }
    }
    // 本机诊断日志（应用专属外部目录的 logs，取不到时退回应用支持目录的 logs）与开发者设置同样只属于这台设备。
    for (final rule in ['<exclude domain="external" path="logs/" />', '<exclude domain="file" path="logs/" />', '<exclude domain="file" path="developer.json" />']) {
      expect(backup, contains(rule));
      expect(rule.allMatches(extraction).length, 2, reason: 'data_extraction_rules 的云备份与换机迁移都要有 $rule');
    }
  });

  // iOS 没有备份规则文件：钥匙串每个命名空间单独的服务名（deleteAll 只清自己）、仅本机级别；安卓排除的目录在组合根逐个标记排除，日志与开发者设置放进 device_only。
  test('iOS 上同样排除安全存储、百宝箱、下载记录、本机日志与私信库', () {
    final sources = [
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart'))) file.readAsStringSync(),
    ];
    final namespaces = {for (final source in sources) for (final match in RegExp(r"storageNamespace: '(\w+)'").allMatches(source)) match.group(1)!};
    for (final namespace in namespaces) {
      expect(sources.join('\n'), contains("IOSOptions(accountName: '$namespace', accessibility: KeychainAccessibility.first_unlock_this_device)"), reason: '$namespace 在 iOS 上要单独的服务名与仅本机级别');
    }
    final extraction = File('android/app/src/main/res/xml/data_extraction_rules.xml').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    final excluded = RegExp(r'excludeFromBackup\(([\s\S]*?)\)\);').firstMatch(main)!.group(1)!;
    for (final match in RegExp(r'<exclude domain="file" path="(\w+)/" />').allMatches(extraction)) {
      final folder = match.group(1)!;
      if (folder == 'logs') continue;
      expect(excluded, contains("'$folder'"), reason: 'iOS 漏了排除 $folder');
    }
    expect(excluded, contains('deviceOnly'));
    expect(main, contains("File(path.join(deviceOnly.path, 'developer.json'))"));
    expect(main, contains("Directory(path.join((external ?? deviceOnly).path, 'logs'))"));
    // 私信库：第一个应用账号沿用的 social.db 与其余账号的 social 文件夹（social/social_spaces.dart），安卓两份规则与 iOS 都排除。
    expect(excluded, contains('File(path.join(socialDirectory, SocialSpaces.legacyDatabase))'));
    expect(excluded, contains('Directory(path.join(socialDirectory, SocialSpaces.accountFolder))'));
    expect(SocialSpaces.legacyDatabase, 'social.db');
    expect(SocialSpaces.accountFolder, 'social');
    for (final rules in [File('android/app/src/main/res/xml/backup_rules.xml').readAsStringSync(), extraction]) {
      expect(rules, allOf(contains('<exclude domain="database" path="social.db" />'), contains('<exclude domain="root" path="databases/social/" />')));
      // database 与 sharedpref 域只能写文件名，写子目录 release 包的 lint 直接报致命错误（CI 不打 release 包，11-14 漏进过 main），文件夹按 root 域写。
      expect(RegExp(r'domain="(?:database|sharedpref)" path="[^"]*/').hasMatch(rules), isFalse);
    }
    expect(File('ios/Runner/AppDelegate.swift').readAsStringSync(), contains('DeviceOnlyData.claimKeychain()'));
  });

  // release 才开 R8，CI 不打 release 包；高德原生 jar 不带混淆规则，删改类名后一开地图就崩（#57）。
  // 11-10 地图改用网页版、原生高德整个删掉（[人工决策] 见 toolbox/chaoxing/chaoxing_web_map.dart）：以后再引回原生 SDK，keep 规则与定位服务声明要一起回来。
  test('原生高德 SDK 与它的混淆规则、清单声明同进同出', () {
    final native = File('pubspec.yaml').readAsStringSync().contains('amap_map:');
    final rules = File('android/app/proguard-rules.pro').readAsStringSync();
    for (final package in ['com.amap.api', 'com.autonavi', 'com.loc']) {
      expect(rules.contains('-keep class $package.** { *; }'), native, reason: package);
    }
    expect(File('android/app/src/main/AndroidManifest.xml').readAsStringSync().contains('com.amap.api.location.APSService'), native);
  });

  // 明文 HTTP 只对教务与中转放行（P2-10）：清单不再全局允许明文，网络安全配置由 android/app/build.gradle.kts 在构建时生成
  // （教务地址写在脚本里，中转地址取构建参数 SUPERXD_RELAY）。CI 不打安卓包，这里只核对清单与脚本里的那几处；生成结果在本机构建时核过。
  test('安卓只对教务与中转放行明文：清单引用生成的网络安全配置，脚本里的教务地址同 kingoBase', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, isNot(contains('usesCleartextTraffic')));
    expect(manifest, contains('android:networkSecurityConfig="@xml/network_security_config"'));
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final edu = Uri.parse(kingoBase);
    expect(edu.scheme, 'http', reason: '教务改成 https 后把它从放行名单里拿掉');
    expect(gradle, contains('val superxdEduHost = "${edu.host}"'));
    expect(gradle, contains('<base-config cleartextTrafficPermitted="false" />'));
    expect(gradle, contains('"SUPERXD_RELAY="'));
    expect(gradle, contains('xml/network_security_config.xml'));
    expect(Directory('android/app/src/main/res/xml').listSync().map((file) => file.uri.pathSegments.last), isNot(contains('network_security_config.xml')), reason: '只用生成的那份');
  });

  // Gradle 依赖校验只核对第三方仓库那几组（[人工决策] 见 android/build.gradle.kts）：信任规则排除的组漏一组就等于没校验，
  // 校验和缺一组构建就失败。
  test('Gradle 依赖校验：信任规则排除的组、记了校验和的组都与限定仓库的组一致', () {
    final gradle = File('android/build.gradle.kts').readAsStringSync();
    final declared = RegExp(r'"(com\.[\w.-]+)"').allMatches(gradle.substring(gradle.indexOf('val thirdPartyRepositoryGroups'), gradle.indexOf('allprojects'))).map((match) => match.group(1)!).toSet();
    expect(declared, isNotEmpty);
    final metadata = File('android/gradle/verification-metadata.xml').readAsStringSync();
    expect(RegExp('<trust ').allMatches(metadata), hasLength(1), reason: '只留一条反向信任规则');
    final trust = RegExp(r'<trust group="\^\(\?!\(([^)]*)\)\$\)\.\*\$" regex="true"/>').firstMatch(metadata);
    expect(trust, isNotNull);
    expect(trust!.group(1)!.split('|').map((group) => group.replaceAll('[.]', '.')).toSet(), declared);
    expect(RegExp(r'<component group="([^"]+)"').allMatches(metadata).map((match) => match.group(1)!).toSet(), declared);
    expect(metadata, contains('<verify-metadata>true</verify-metadata>'));
  });
}
