import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/application/rollouts.dart';
import 'package:superxd/device/relay_release_feed.dart';
import 'package:superxd/device/relay_rollout_feed.dart';
import 'package:superxd/device/signed_content.dart';
import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/local/rollout_memory.dart';

import '../tool/content_signing.dart';
import '../tool/release_manifest.dart';
import '../tool/rollout_config.dart';
import 'app_update_fakes.dart';
import 'content_signing_support.dart';

// 灰度与分批更新（人工决策见 lib/domain/rollout.dart）：分桶、配置解析、本机记录、编排、签名下发与发版清单的放量表。合成数据。
final _day1 = DateTime.utc(2026, 11, 14);

List<RolloutStage> _stages() => [
  RolloutStage(from: _day1, percent: 20),
  RolloutStage(from: _day1.add(const Duration(days: 1)), percent: 50),
  RolloutStage(from: _day1.add(const Duration(days: 2)), percent: 100),
];

class _Feed implements RolloutFeed {
  RolloutConfig? next;
  int fetches = 0;
  @override
  Future<RolloutConfig> fetch() async {
    fetches++;
    return next ?? (throw const RolloutException('连不上服务器'));
  }
}

void main() {
  group('分桶', () {
    test('与服务端共用向量', () {
      final vectors = jsonDecode(File('server/test/vectors/rollout_v1.json').readAsStringSync()) as Map<String, dynamic>;
      for (final item in (vectors['cases'] as List).cast<Map<String, dynamic>>()) {
        expect(rolloutBucket(item['id'] as String, item['subject'] as String), item['bucket']);
      }
    });

    test('放量只涨时进了批次的一直在里面，比例接近放量值，换版本重新分桶', () {
      final subjects = [for (var index = 0; index < 4000; index++) 'subject-$index'];
      final at20 = subjects.where((subject) => rolloutIncludes('app_update.alpha.28', subject, 20)).toSet();
      final at50 = subjects.where((subject) => rolloutIncludes('app_update.alpha.28', subject, 50)).toSet();
      expect(at50.containsAll(at20), isTrue);
      expect(at20.length / subjects.length, closeTo(0.2, 0.03));
      expect(at50.length / subjects.length, closeTo(0.5, 0.03));
      final next = subjects.where((subject) => rolloutIncludes('app_update.alpha.29', subject, 20)).toSet();
      expect(next.difference(at20), isNotEmpty);
      expect(subjects.where((subject) => rolloutIncludes('x', subject, 0)), isEmpty);
      expect(subjects.every((subject) => rolloutIncludes('x', subject, 100)), isTrue);
    });

    test('放量表按时刻取档，还没开始为 0，定值不看时刻', () {
      final rule = RolloutRule(id: 'x', stages: _stages());
      expect(rule.percentAt(_day1.subtract(const Duration(seconds: 1))), 0);
      expect(rule.percentAt(_day1), 20);
      expect(rule.percentAt(_day1.add(const Duration(hours: 30))), 50);
      expect(rule.percentAt(_day1.add(const Duration(days: 9))), 100);
      expect(const RolloutRule(id: 'x', percent: 7).percentAt(_day1), 7);
    });
  });

  group('配置', () {
    test('定值与放量表都认，读回来再写一样', () {
      final config = decodeRolloutConfig({
        'flags': [
          {'id': 'challenge', 'percent': 10},
          {'id': 'app_update.alpha.28', 'stages': [{'from': '2026-11-14T08:00:00+08:00', 'percent': 20}, {'from': '2026-11-15T00:00:00Z', 'percent': 100}]},
        ],
      });
      expect(config.rules['challenge']!.percent, 10);
      expect(config.rules['app_update.alpha.28']!.stages.first.from, DateTime.utc(2026, 11, 14));
      expect(jsonEncode(encodeRolloutConfig(decodeRolloutConfig(encodeRolloutConfig(config)))), jsonEncode(encodeRolloutConfig(config)));
    });

    test('外部输入：格式不对、开关重复、放量倒退、时刻不带时区都不认', () {
      for (final bad in <Object?>[
        null,
        {'flags': 'x'},
        {'flags': <Object?>[], 'extra': 1},
        {'flags': [{'id': 'Bad Id', 'percent': 1}]},
        {'flags': [{'id': 'x', 'percent': 101}]},
        {'flags': [{'id': 'x', 'percent': 1, 'stages': <Object?>[]}]},
        {'flags': [{'id': 'x', 'percent': 1}, {'id': 'x', 'percent': 2}]},
        {'flags': [{'id': 'x', 'stages': <Object?>[]}]},
        {'flags': [{'id': 'x', 'stages': [{'from': '2026-11-14T00:00:00', 'percent': 1}]}]},
        {'flags': [{'id': 'x', 'stages': [{'from': '2026-11-15T00:00:00Z', 'percent': 50}, {'from': '2026-11-14T00:00:00Z', 'percent': 60}]}]},
        {'flags': [{'id': 'x', 'stages': [{'from': '2026-11-14T00:00:00Z', 'percent': 50}, {'from': '2026-11-15T00:00:00Z', 'percent': 20}]}]},
        {'flags': [for (var index = 0; index <= rolloutRuleLimit; index++) {'id': 'f$index', 'percent': 1}]},
      ]) {
        expect(() => decodeRolloutConfig(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('仓库里的 rollout/rollout.json 格式正确（不对的 PR 合并不了）', () async {
      final config = await readRolloutConfig(File('rollout/rollout.json'));
      expect(config.rules.length, lessThanOrEqualTo(rolloutRuleLimit));
    });
  });

  group('签名下发', () {
    test('只认开发者的话那把钥签的 rollout，发版钥或别的类的签名不认；中转还没放时是空配置', () async {
      final signing = await TestSigning.create();
      final plain = encodeRolloutConfig(decodeRolloutConfig({'flags': [{'id': 'challenge', 'percent': 10}]}));
      final signed = await decodeSignedRolloutConfig({...plain, 'envelope': await signing.seal(plain, SignedContent.rollout, [signing.rollout])}, keys: signing.keys);
      expect(signed.rules['challenge']!.percent, 10);
      expect(decodeSignedRolloutConfig({...plain, 'envelope': await signing.seal(plain, SignedContent.release, [signing.release])}, keys: signing.keys), throwsA(isA<SignedEnvelopeException>()));
      expect(decodeSignedRolloutConfig({...plain, 'envelope': await signing.seal(plain, SignedContent.notes, [signing.notes])}, keys: signing.keys), throwsA(isA<SignedEnvelopeException>()));
      expect(decodeSignedRolloutConfig(plain, keys: signing.keys), throwsA(isA<SignedEnvelopeException>()));
      expect((await decodeSignedRolloutConfig({'flags': <Object?>[], 'envelope': null}, keys: signing.keys)).rules, isEmpty);
    });

    test('配置工具签好的文件过得了流水线的核对，明文被改了核对不过', () async {
      final signing = await TestSigning.create();
      final config = decodeRolloutConfig({'flags': [{'id': 'app_update.alpha.28', 'percent': 50}]});
      final file = jsonDecode(await encodeRolloutFile(config, [signing.rollout])) as Map<String, Object?>;
      await checkRolloutConfig(file, keys: signing.keys);
      expect(checkRolloutConfig({...file, 'flags': [{'id': 'app_update.alpha.28', 'percent': 100}]}, keys: signing.keys), throwsFormatException);
    });
  });

  group('发版清单的放量表', () {
    test('每天一档、只增、最后 100；写进每个架构的签名载荷，客户端读得出', () async {
      final published = DateTime.utc(2026, 11, 14, 4);
      final stages = rolloutStagesOf('20,50,100', published);
      expect(stages.map((stage) => stage['percent']), [20, 50, 100]);
      expect(stages.last['from'], published.add(const Duration(days: 2)).toIso8601String());
      for (final bad in ['', '50,20,100', '20,50', '0,100', '20,abc,100', List.filled(rolloutStageLimit + 1, '100').join(',')]) {
        expect(() => rolloutStagesOf(bad, published), throwsFormatException, reason: bad);
      }
      final signing = await TestSigning.create();
      final manifest = {
        'versionCode': 28, 'versionName': '1.0.0-alpha.17', 'publishedAt': published.toIso8601String(), 'minSupportedVersionCode': 0, 'notes': '合成说明',
        'releasePage': 'https://github.com/huverse/SuperXD/releases/tag/v1.0.0-alpha.17',
        'apks': [for (final abi in releaseAbis) {'abi': abi, 'file': 'SuperXD-1.0.0-alpha.17-$abi.apk', 'size': 10, 'sha256': 'a' * 64}],
      };
      final signed = await signReleaseManifest(manifest, channel: 'alpha', signers: [signing.release], rollout: stages);
      await checkReleaseManifest(signed, channel: 'alpha', keys: signing.keys);
      final response = {...signed, 'envelope': (signed['envelopes']! as Map)['arm64-v8a']}..remove('envelopes')..remove('apks');
      final release = await parseSignedAppRelease(response, baseUrl: 'http://relay.invalid', channel: 'alpha', abi: 'arm64-v8a', keys: signing.keys);
      expect(release.rollout.map((stage) => stage.percent), [20, 50, 100]);
      // 明文字段不带放量表（中转按白名单校验明文清单）。
      expect(signed.containsKey('rollout'), isFalse);
      final full = await signReleaseManifest(manifest, channel: 'alpha', signers: [signing.release]);
      final fullResponse = {...full, 'envelope': (full['envelopes']! as Map)['arm64-v8a']}..remove('envelopes')..remove('apks');
      expect((await parseSignedAppRelease(fullResponse, baseUrl: 'http://relay.invalid', channel: 'alpha', abi: 'arm64-v8a', keys: signing.keys)).rollout, isEmpty);
    });
  });

  group('编排', () {
    late DateTime now;
    late String? accountId;
    late _Feed feed;
    late FileRolloutMemory memory;
    late Rollouts rollouts;
    setUp(() {
      now = _day1;
      accountId = null;
      feed = _Feed();
      memory = FileRolloutMemory.memory();
      rollouts = Rollouts(memory: memory, channel: 'alpha', accountId: () => accountId, feed: feed, now: () => now);
    });

    AppRelease release({List<RolloutStage> rollout = const []}) => AppRelease(
      versionCode: 28, versionName: '1.0.0-alpha.17', publishedAt: _day1, minSupportedVersionCode: 0, notes: '', releasePage: Uri.parse('https://example.invalid'), apk: null, rollout: rollout,
    );

    // 找一个在 20% 里的主体与一个只在 50% 才进的主体。
    (String, String) subjects() {
      final id = appUpdateRolloutId('alpha', 28);
      final candidates = Iterable<String>.generate(1000, (index) => 'subject-$index');
      final inside = candidates.firstWhere((subject) => rolloutIncludes(id, subject, 20));
      final later = candidates.firstWhere((subject) => !rolloutIncludes(id, subject, 20) && rolloutIncludes(id, subject, 50));
      return (inside, later);
    }

    test('清单的放量表按当前时刻与主体判定；没写放量表是全量', () {
      final (inside, later) = subjects();
      final staged = release(rollout: _stages());
      expect(rollouts.inUpdateBatch(release()), isTrue);
      accountId = inside;
      expect(rollouts.inUpdateBatch(staged), isTrue);
      accountId = later;
      expect(rollouts.inUpdateBatch(staged), isFalse);
      now = _day1.add(const Duration(days: 1));
      expect(rollouts.inUpdateBatch(staged), isTrue);
      now = _day1.subtract(const Duration(hours: 1));
      accountId = inside;
      expect(rollouts.inUpdateBatch(staged), isFalse, reason: '还没到第一档');
    });

    test('没登录应用账号用本机随机编号分桶', () {
      expect(rollouts.subject, memory.installId);
      accountId = 'AAAAAAAAAAAAAAAAAAAAAB';
      expect(rollouts.subject, 'AAAAAAAAAAAAAAAAAAAAAB');
    });

    test('配置里同名开关覆盖清单：暂停在定值、直接全量、整版关停；功能开关没配用默认值', () async {
      final (_, later) = subjects();
      accountId = later;
      final staged = release(rollout: _stages());
      feed.next = decodeRolloutConfig({'flags': [{'id': 'app_update.alpha.28', 'percent': 100}, {'id': 'challenge', 'percent': 0}]});
      await rollouts.refresh();
      expect(rollouts.inUpdateBatch(staged), isTrue);
      expect(rollouts.enabled('challenge', fallback: true), isFalse);
      expect(rollouts.enabled('unknown', fallback: true), isTrue);
      now = now.add(Rollouts.refreshGap);
      feed.next = decodeRolloutConfig({'flags': [{'id': 'app_update.alpha.28', 'percent': 0}]});
      await rollouts.refresh();
      expect(rollouts.inUpdateBatch(release()), isFalse, reason: '全量的版本也能整版关停');
    });

    test('拉配置隔一小时，失败照旧用上次的', () async {
      feed.next = decodeRolloutConfig({'flags': [{'id': 'challenge', 'percent': 100}]});
      await rollouts.refresh();
      await rollouts.refresh();
      expect(feed.fetches, 1);
      now = now.add(Rollouts.refreshGap);
      feed.next = null;
      await rollouts.refresh();
      expect(feed.fetches, 2);
      expect(rollouts.enabled('challenge', fallback: false), isTrue);
    });

    test('没配中转时不联网，开关按默认值', () async {
      final offline = Rollouts(memory: FileRolloutMemory.memory(), channel: 'alpha', accountId: () => null, now: () => now);
      await offline.refresh();
      expect(offline.enabled('challenge', fallback: false), isFalse);
    });
  });

  group('本机记录', () {
    late Directory directory;
    setUp(() async => directory = await Directory.systemTemp.createTemp('rollout-'));
    tearDown(() => directory.delete(recursive: true));

    test('第一次生成随机编号并存下，配置与时刻存得住；坏文件当没有、编号重新生成', () async {
      final file = File('${directory.path}/rollout.json');
      final first = await FileRolloutMemory.open(file);
      expect(first.installId, hasLength(22));
      await first.save(decodeRolloutConfig({'flags': [{'id': 'challenge', 'percent': 5}]}), DateTime.utc(2026, 11, 14, 1));
      final again = await FileRolloutMemory.open(file);
      expect(again.installId, first.installId);
      expect(again.config.rules['challenge']!.percent, 5);
      expect(again.fetchedAt, DateTime.utc(2026, 11, 14, 1));
      await file.writeAsString('{broken');
      final reset = await FileRolloutMemory.open(file);
      expect(reset.installId, isNot(first.installId));
      expect(reset.config.rules, isEmpty);
    });
  });

  group('应用更新按批次', () {
    test('自动检查不在这一批就当没有，手动检查照常给；必须更新不受批次限制', () async {
      var inBatch = false;
      final fixture = UpdateFixture(inBatch: (release) => inBatch);
      fixture.feed.next = fakeRelease();
      await fixture.updates.autoCheck();
      expect(fixture.updates.urgency, AppUpdateUrgency.none);
      expect(fixture.updates.takePrompt(), isNull);
      await fixture.updates.check();
      expect(fixture.updates.urgency, AppUpdateUrgency.optional);
      fixture.now = fixture.now.add(const Duration(days: 1));
      fixture.feed.next = fakeRelease(minSupported: 5);
      await fixture.updates.autoCheck();
      expect(fixture.updates.urgency, AppUpdateUrgency.forced);
      fixture.now = fixture.now.add(const Duration(days: 1));
      fixture.feed.next = fakeRelease();
      inBatch = true;
      await fixture.updates.autoCheck();
      expect(fixture.updates.takePrompt(), isNotNull);
    });
  });
}
