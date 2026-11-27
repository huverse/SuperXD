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

    // [人工决策-2026-11-17 21:24:25] 见 lib/domain/app_health.dart：只发档位，原始时长与帧数只在本机。
    test('性能档位：启动按 0.5/1/2 秒分四档、一天取中位档；慢帧占比按 5%/15%/40% 分四档，帧太少不报', () {
      expect([400, 500, 999, 1000, 1999, 2000, 9000].map((ms) => healthLaunchTier(Duration(milliseconds: ms))), [0, 1, 1, 2, 2, 3, 3]);
      const empty = HealthDay(day: '2026-11-15', versionCode: 30);
      expect((empty.launchTier, empty.frameTier), (null, null));
      var day = empty;
      for (final ms in [300, 2500, 700]) {
        day = day.withLaunch(Duration(milliseconds: ms));
      }
      expect(day.launches, [1, 1, 0, 1]);
      expect(day.launchTier, 1);
      expect(day.withLaunch(const Duration(seconds: 3)).launchTier, 1, reason: '偶数次取低的那个中位');
      expect(day.withLaunch(const Duration(seconds: 3)).withLaunch(const Duration(seconds: 3)).launchTier, 3);
      expect(empty.copyWith(frames: healthFrameMinimum - 1, slowFrames: 0).frameTier, isNull);
      expect([0, 29, 30, 89, 90, 239, 240, 600].map((slow) => empty.copyWith(frames: 600, slowFrames: slow).frameTier), [0, 0, 1, 1, 2, 2, 3, 3]);
    });

    // [人工决策-2026-11-27 13:28:05] 见 lib/domain/app_health.dart：每天每个用过的版本一项，上次退出原因按时刻认版本。
    test('某一刻在用的版本：第一次记下不晚于它的最后一项，都晚于它取最早的，没有时刻的当这天开头；超过项数上限先丢最早的日子', () {
      final old = HealthDay(day: '2026-11-15', versionCode: 30, since: DateTime.utc(2026, 11, 15, 0));
      final updated = HealthDay(day: '2026-11-15', versionCode: 31, since: DateTime.utc(2026, 11, 15, 7));
      final days = [updated, old, const HealthDay(day: '2026-11-14', versionCode: 30)];
      expect(healthDayAt(days, '2026-11-15', DateTime.utc(2026, 11, 15, 1))?.versionCode, 30);
      expect(healthDayAt(days, '2026-11-15', DateTime.utc(2026, 11, 15, 7))?.versionCode, 31);
      expect(healthDayAt(days, '2026-11-15', DateTime.utc(2026, 11, 14, 17))?.versionCode, 30, reason: '记下之前就出了错');
      expect(healthDayAt(days, '2026-11-14', DateTime.utc(2026, 11, 14, 4))?.versionCode, 30, reason: '旧记录没有时刻');
      expect(healthDayAt(days, '2026-11-13', DateTime.utc(2026, 11, 13, 4)), isNull);
      final many = [
        for (var day = 10; day <= 16; day++)
          for (final versionCode in [30, 31, 32]) HealthDay(day: '2026-11-$day', versionCode: versionCode),
      ];
      final kept = healthRecent(many, '2026-11-16');
      expect(kept, hasLength(healthEntryLimit));
      expect(kept.map((day) => day.day).toSet(), {for (var day = 12; day <= 16; day++) '2026-11-$day'}, reason: '先丢最早的日子');
      expect(kept.where((day) => day.day == '2026-11-12'), hasLength(2), reason: '保留最新的 14 项');
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
      await memory.save(HealthRecord(days: [HealthDay(day: '2026-11-15', versionCode: 30, fatal: true, since: DateTime.utc(2026, 11, 15, 1, 2))], versionCode: 30, versionSince: '2026-11-10', feedbackSent: true));
      final again = (await FileAppHealthMemory.open(file)).record;
      expect((again.days.single.day, again.days.single.fatal, again.days.single.since, again.versionSince, again.feedbackSent), ('2026-11-15', true, DateTime.utc(2026, 11, 15, 1, 2), '2026-11-10', true));
      final json = jsonDecode(await file.readAsString()) as Map;
      (json['days'] as List).add({'day': 'x', 'versionCode': 30, 'fatal': false, 'reported': false});
      (json['days'] as List).add({'day': '2026-11-16', 'versionCode': 30, 'fatal': false, 'reported': false, 'since': '昨天'});
      await file.writeAsString(jsonEncode(json));
      final read = (await FileAppHealthMemory.open(file)).record.days;
      expect([for (final day in read) (day.day, day.since == null)], [('2026-11-15', false), ('2026-11-16', true)], reason: '坏项丢掉，坏的时刻当没有');
      await file.writeAsString('{坏');
      expect((await FileAppHealthMemory.open(file)).record.days, isEmpty);
    });

    test('性能档位的原始数写得下读得回；坏的当没有', () async {
      final directory = await Directory.systemTemp.createTemp('health');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/health.json');
      final memory = await FileAppHealthMemory.open(file);
      await memory.save(const HealthRecord(days: [HealthDay(day: '2026-11-15', versionCode: 30, launches: [2, 1, 0, 0], frames: 900, slowFrames: 50)]));
      final day = (await FileAppHealthMemory.open(file)).record.days.single;
      expect(day.launches, [2, 1, 0, 0]);
      expect((day.frames, day.slowFrames, day.launchTier, day.frameTier), (900, 50, 0, 1));
      await file.writeAsString(jsonEncode({
        'days': [
          {'day': '2026-11-15', 'versionCode': 30, 'fatal': false, 'reported': false, 'launches': [1, 2], 'frames': -5, 'slowFrames': 3},
          {'day': '2026-11-16', 'versionCode': 30, 'fatal': false, 'reported': false, 'launches': 'x', 'frames': 100, 'slowFrames': 900},
        ],
      }));
      final days = (await FileAppHealthMemory.open(file)).record.days;
      expect([for (final day in days) day.launches], [isEmpty, isEmpty]);
      expect([for (final day in days) (day.frames, day.slowFrames)], [(0, 0), (100, 100)]);
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

    test('启动用时与帧数记进当天（帧数在内存里攒着、切后台或过了日界才写）；回报带档位', () async {
      final subject = health();
      await subject.markLaunch(const Duration(milliseconds: 1500));
      await subject.markActive();
      await subject.markLaunch(const Duration(milliseconds: 1200));
      expect(memory.record.days.single.launches, [0, 0, 2, 0]);
      expect(memory.record.days.single.launchTier, 2);
      subject.countFrames(500, 10);
      subject.countFrames(500, 90);
      expect(memory.record.days.single.frames, 0, reason: '没切后台不写盘');
      await subject.flushFrames();
      expect((memory.record.days.single.frames, memory.record.days.single.slowFrames), (1000, 100));
      await subject.flushFrames();
      expect(memory.record.days.single.frames, 1000, reason: '写过的不重复加');
      subject.countFrames(200, 200);
      // 跨过日界：前一天攒着的先记到前一天。
      now = _noon(11, 16);
      subject.countFrames(700, 0);
      await Future<void>.delayed(Duration.zero);
      await subject.flushFrames();
      final days = {for (final day in memory.record.days) day.day: day};
      expect((days['2026-11-15']!.frames, days['2026-11-15']!.slowFrames, days['2026-11-15']!.frameTier), (1200, 300, 2));
      expect((days['2026-11-16']!.frames, days['2026-11-16']!.launchTier), (700, null));
      await subject.reportDue();
      expect((client.reports.single.day, client.reports.single.launchTier, client.reports.single.frameTier), ('2026-11-15', 2, 2));
    });

    test('升级当天：新旧版本各一项，启动、帧数与致命错误各记各的，第二天各发一份', () async {
      now = DateTime.utc(2026, 11, 15, 0);
      final old = health(versionCode: 30);
      await old.markActive();
      await old.markLaunch(const Duration(milliseconds: 300));
      await old.markFatal(now);
      now = DateTime.utc(2026, 11, 15, 7);
      final updated = health(versionCode: 31);
      await updated.markActive();
      await updated.markLaunch(const Duration(seconds: 3));
      updated.countFrames(700, 0);
      await updated.flushFrames();
      final days = {for (final day in memory.record.days) day.versionCode: day};
      expect(days.keys, {30, 31});
      expect([days[30]!.fatal, days[30]!.launches, days[30]!.frames], [true, [1, 0, 0, 0], 0]);
      expect([days[31]!.fatal, days[31]!.launches, days[31]!.frames], [false, [0, 0, 0, 1], 700], reason: '旧版本的致命不带进新版本');
      now = _noon(11, 16);
      await updated.reportDue();
      expect([for (final day in client.reports) (day.day, day.versionCode, day.fatal)]..sort((left, right) => left.$2.compareTo(right.$2)), [('2026-11-15', 30, true), ('2026-11-15', 31, false)]);
      expect(healthDue(memory.record, '2026-11-16'), isEmpty, reason: '两项都记成发过');
    });

    test('上次退出原因按出错时刻认版本：升级前的崩溃记到旧版本，升级后的记到新版本，那天没有记录才算现在的版本', () async {
      now = DateTime.utc(2026, 11, 15, 0);
      await health(versionCode: 30).markActive();
      now = DateTime.utc(2026, 11, 15, 7);
      final updated = health(versionCode: 31);
      await updated.markExit(DateTime.utc(2026, 11, 15, 3));
      await updated.markActive();
      expect({for (final day in memory.record.days) day.versionCode: day.fatal}, {30: true, 31: false}, reason: '新版本第一次启动前记下的也认到旧版本');
      await updated.markExit(DateTime.utc(2026, 11, 15, 8));
      expect({for (final day in memory.record.days) day.versionCode: day.fatal}, {30: true, 31: true});
      await updated.markExit(DateTime.utc(2026, 11, 14, 4));
      expect([for (final day in memory.record.days) if (day.day == '2026-11-14') (day.versionCode, day.fatal)], [(31, true)]);
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
      expect(jsonDecode(requests.single.body), {'channel': 'alpha', 'platform': 'android', 'versionCode': 30, 'day': '2026-11-15', 'fatal': true}, reason: '没有档位的不带');
      await client.report(channel: 'alpha', platform: 'android', day: const HealthDay(day: '2026-11-15', versionCode: 30, launches: [0, 3, 0, 0], frames: 800, slowFrames: 400));
      expect(jsonDecode(requests.last.body), {'channel': 'alpha', 'platform': 'android', 'versionCode': 30, 'day': '2026-11-15', 'fatal': false, 'launch': 1, 'frames': 3}, reason: '只带档位，不带原始时长与帧数');
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
      Future<RolloutConfig> fetch(Object? paused) async => (await RelayRolloutFeed('https://relay.invalid', keys: signing.keys, client: MockClient((request) async {
        return http.Response.bytes(utf8.encode(jsonEncode({...flags, 'paused': paused})), 200);
      })).fetch()).config!;
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
