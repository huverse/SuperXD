import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:superxd/app_diagnostics.dart';
import 'package:superxd/application/app_health.dart';
import 'package:superxd/application/rollouts.dart';
import 'package:superxd/device/relay_app_health.dart';
import 'package:superxd/device/relay_rollout_feed.dart';
import 'package:superxd/domain/app_health.dart';
import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/local/app_health_memory.dart';
import 'package:superxd/local/rollout_memory.dart';
import 'package:superxd/page/about_page.dart';
import 'package:superxd/theme/campus_theme.dart';

import '../tool/rollout_config.dart';
import 'content_signing_support.dart';

// 分批更新的健康回报与意见反馈（人工决策见 lib/domain/app_health.dart 与服务端 app_health_rules.ts）。合成数据。
class _Client implements AppHealthClient {
  final reports = <HealthDay>[];
  final feedbacks = <({bool good, String text, int versionCode})>[];
  AppHealthException? failure;

  @override
  Future<void> report({required String channel, required String platform, required HealthDay day}) async {
    if (failure case final failure?) throw failure;
    reports.add(day);
  }

  @override
  Future<void> feedback({required String channel, required String platform, required int versionCode, required bool good, required String text}) async {
    if (failure case final failure?) throw failure;
    feedbacks.add((good: good, text: text, versionCode: versionCode));
  }
}

// 校园时区某天中午。
DateTime _noon(int month, int day) => DateTime.utc(2026, month, day, 4);

void main() {
  group('规则', () {
    test('该发的：过完的、没发过的，从新到旧最多 3 天；只留最近 7 天', () {
      final record = HealthRecord(days: [
        for (var day = 5; day <= 16; day++) HealthDay(day: '2026-11-${day.toString().padLeft(2, '0')}', versionCode: 30, reported: day == 14),
      ]);
      expect(healthDue(record, '2026-11-16').map((day) => day.day), ['2026-11-15', '2026-11-13', '2026-11-12']);
      expect(healthRecent(record.days, '2026-11-16').first.day, '2026-11-10');
    });

    test('新版本反馈：这个版本装了不到 14 天、没交过', () {
      const record = HealthRecord(versionCode: 30, versionSince: '2026-11-10');
      expect(healthFeedbackOpen(record, 30, '2026-11-23'), isTrue);
      expect(healthFeedbackOpen(record, 30, '2026-11-24'), isFalse);
      expect(healthFeedbackOpen(record, 31, '2026-11-16'), isFalse);
      expect(healthFeedbackOpen(const HealthRecord(versionCode: 30, versionSince: '2026-11-10', feedbackSent: true), 30, '2026-11-16'), isFalse);
    });
  });

  group('本机记录', () {
    test('写下再读回；坏项丢掉、坏文件当没有', () async {
      final directory = await Directory.systemTemp.createTemp('health');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/health.json');
      final memory = await FileAppHealthMemory.open(file);
      await memory.save(const HealthRecord(days: [HealthDay(day: '2026-11-15', versionCode: 30, fatal: true)], versionCode: 30, versionSince: '2026-11-10', feedbackSent: true));
      final again = (await FileAppHealthMemory.open(file)).record;
      expect((again.days.single.day, again.days.single.fatal, again.versionSince, again.feedbackSent), ('2026-11-15', true, '2026-11-10', true));
      final json = jsonDecode(await file.readAsString()) as Map;
      (json['days'] as List).add({'day': 'x', 'versionCode': 30, 'fatal': false, 'reported': false});
      await file.writeAsString(jsonEncode(json));
      expect((await FileAppHealthMemory.open(file)).record.days, hasLength(1));
      await file.writeAsString('{坏');
      expect((await FileAppHealthMemory.open(file)).record.days, isEmpty);
    });
  });

  group('编排（AppHealth）', () {
    late DateTime now;
    late _Client client;
    late FileAppHealthMemory memory;
    AppHealth health({int versionCode = 30, AppHealthClient? override, bool relay = true}) =>
        AppHealth(memory: memory, channel: 'alpha', platform: 'android', versionCode: versionCode, client: relay ? (override ?? client) : null, clock: () => now);
    setUp(() {
      now = _noon(11, 15);
      client = _Client();
      memory = FileAppHealthMemory.memory();
    });

    test('记今天打开过与版本；换版本从那天起算反馈窗口、交过的作废；致命错误记到出错那天', () async {
      final subject = health();
      await subject.markActive();
      expect(memory.record.days.single.day, '2026-11-15');
      expect(subject.feedbackOpen, isTrue);
      await subject.sendFeedback(good: true, text: '  顺手 ');
      expect(client.feedbacks.single, (good: true, text: '顺手', versionCode: 30));
      expect(subject.feedbackOpen, isFalse);
      now = _noon(11, 16);
      await subject.markFatal(_noon(11, 15));
      await subject.markFatal(_noon(11, 17));
      expect(memory.record.days.where((day) => day.fatal).map((day) => day.day), ['2026-11-15'], reason: '将来的不记');
      final updated = health(versionCode: 31);
      await updated.markActive();
      expect((memory.record.versionCode, memory.record.versionSince, memory.record.feedbackSent), (31, '2026-11-16', false));
      expect(updated.feedbackOpen, isTrue);
      expect(health(relay: false).feedbackOpen, isFalse, reason: '没配中转不给入口');
    });

    test('发过完的、没发过的；连不上留着下次，服务器拒收记成发过；今天的不发', () async {
      final subject = health();
      await subject.markActive();
      await subject.markFatal(_noon(11, 15));
      now = _noon(11, 16);
      await subject.markActive();
      client.failure = const AppHealthException('连不上服务器');
      await subject.reportDue();
      expect(healthDue(memory.record, '2026-11-16'), hasLength(1));
      client.failure = null;
      await subject.reportDue();
      expect(client.reports.single.day, '2026-11-15');
      expect(client.reports.single.fatal, isTrue);
      expect(healthDue(memory.record, '2026-11-16'), isEmpty);
      now = _noon(11, 17);
      client.failure = const AppHealthException('服务器回了 400', rejected: true);
      await subject.reportDue();
      expect(healthDue(memory.record, '2026-11-17'), isEmpty, reason: '拒收的不再重发');
    });

    test('上次退出原因里的崩溃与无响应交出系统记下的时刻，后台被回收不算', () async {
      final directory = await Directory.systemTemp.createTemp('exit');
      addTearDown(() => directory.delete(recursive: true));
      final at = <DateTime>[];
      ({int timestamp, String reason, int status, int importance, int pssKb, int rssKb, String description, String trace}) exit(int timestamp, String reason, int importance) =>
          (timestamp: timestamp, reason: reason, status: 0, importance: importance, pssKb: 0, rssKb: 0, description: '', trace: '');
      await recordExitReasons(
        marker: File('${directory.path}/marker'),
        read: (since) async => [exit(3000, 'LOW_MEMORY', 400), exit(2000, 'ANR', 100), exit(1000, 'CRASH', 100)],
        onAbnormal: at.add,
      );
      expect(at, [DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true), DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true)]);
    });
  });

  group('中转与暂停', () {
    test('健康回报与意见：路径与内容（不带标识），204 成功、429 限流、4xx 拒收', () async {
      final requests = <http.Request>[];
      var status = 204;
      final client = RelayAppHealthClient('https://relay.invalid', client: MockClient((request) async {
        requests.add(request);
        return http.Response('', status);
      }));
      await client.report(channel: 'alpha', platform: 'android', day: const HealthDay(day: '2026-11-15', versionCode: 30, fatal: true));
      expect(requests.single.url.path, '/v1/app/health');
      expect(jsonDecode(requests.single.body), {'channel': 'alpha', 'platform': 'android', 'versionCode': 30, 'day': '2026-11-15', 'fatal': true});
      await client.feedback(channel: 'alpha', platform: 'ios', versionCode: 30, good: false, text: '卡');
      expect(requests.last.url.path, '/v1/app/feedback');
      expect(jsonDecode(requests.last.body), {'channel': 'alpha', 'platform': 'ios', 'versionCode': 30, 'good': false, 'text': '卡'});
      status = 429;
      await expectLater(client.feedback(channel: 'alpha', platform: 'ios', versionCode: 30, good: false, text: ''), throwsA(isA<AppHealthException>().having((error) => error.rejected, 'rejected', isFalse)));
      status = 400;
      await expectLater(client.report(channel: 'alpha', platform: 'android', day: const HealthDay(day: '2026-11-15', versionCode: 30)), throwsA(isA<AppHealthException>().having((error) => error.rejected, 'rejected', isTrue)));
    });

    test('第 2 版回复里不签名的 paused 只让自动检查不提示这一版；名单不合格整份不用；签名载荷里的不认', () async {
      final signing = await TestSigning.create();
      final flags = jsonDecode(await encodeFlagsFile(decodeRolloutConfig({'flags': <Object?>[], 'paused': ['app_update.alpha.31']}), [signing.rollout])) as Map<String, Object?>;
      Future<RolloutConfig> fetch(Object? paused) => RelayRolloutFeed('https://relay.invalid', keys: signing.keys, client: MockClient((request) async {
        return http.Response.bytes(utf8.encode(jsonEncode({...flags, 'paused': paused})), 200);
      })).fetch();
      expect((await fetch(['app_update.alpha.30'])).paused, {'app_update.alpha.30'}, reason: '签名载荷里的 31 不认');
      expect((await fetch(['app_update.alpha.30', 'game.flash'])).paused, isEmpty);
      expect((await fetch('x')).paused, isEmpty);
      final memory = FileRolloutMemory.memory(config: await fetch(['app_update.alpha.30']));
      final rollouts = Rollouts(memory: memory, channel: 'alpha', platform: 'android', versionCode: 29, accountId: () => null, feed: null, now: () => _noon(11, 16));
      AppRelease release(int versionCode) => AppRelease(versionCode: versionCode, versionName: 'x', publishedAt: _noon(11, 1), minSupportedVersionCode: 0, notes: '', releasePage: Uri.parse('https://example.invalid'), apk: null);
      expect(rollouts.inUpdateBatch(release(30)), isFalse);
      expect(rollouts.inUpdateBatch(release(31)), isTrue);
      expect(decodeRolloutConfig(encodeRolloutConfig(memory.config)).paused, {'app_update.alpha.30'}, reason: '本机存得住');
    });
  });

  group('关于页', () {
    testWidgets('装了新版本 14 天内有「新版本反馈」：选好或不好才能提交，提交后提示并收起入口；失败原地写原因', (tester) async {
      final client = _Client();
      final memory = FileAppHealthMemory.memory();
      final health = AppHealth(memory: memory, channel: 'alpha', platform: 'android', versionCode: 30, client: client, clock: () => _noon(11, 16));
      await health.markActive();
      final info = PackageInfo(appName: 'SuperXD', packageName: 'p', version: '1', buildNumber: '30');
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: AboutPage(packageInfo: Future.value(info), health: health)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新版本反馈'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交')).onPressed, isNull);
      await tester.tap(find.text('不好用'));
      await tester.enterText(find.byType(TextField), '启动慢');
      await tester.pump();
      client.failure = const AppHealthException('连不上服务器');
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(find.text('连不上服务器'), findsOneWidget);
      client.failure = null;
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(client.feedbacks.single, (good: false, text: '启动慢', versionCode: 30));
      expect(find.text('收到了，谢谢'), findsOneWidget);
      expect(find.text('新版本反馈'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
