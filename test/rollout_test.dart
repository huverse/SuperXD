import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/application/rollouts.dart';
import 'package:superxd/device/relay_release_feed.dart';
import 'package:superxd/device/relay_rollout_feed.dart';
import 'package:superxd/device/signed_content.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/local/rollout_memory.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/relay/relay_client.dart';
import 'package:superxd/relay/relay_flag_target_client.dart';
import 'package:superxd/relay/relay_crypto.dart';

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
  // 带来的版本号（条件请求），与这次给出的版本号；unchanged 为真时回「没变」。
  final etags = <String?>[];
  String served = 'rev-1';
  bool unchanged = false;
  @override
  Future<RolloutFetch> fetch({String? etag}) async {
    fetches++;
    etags.add(etag);
    if (unchanged) return RolloutFetch(null, etag: etag);
    return RolloutFetch(next ?? (throw const RolloutException('连不上服务器')), etag: served);
  }
}

void main() {
  group('分桶', () {
    test('与服务端共用向量', () {
      final vectors = jsonDecode(File('server/test/vectors/rollout_v1.json').readAsStringSync()) as Map<String, dynamic>;
      for (final item in (vectors['cases'] as List).cast<Map<String, dynamic>>()) {
        expect(rolloutBucket(item['id'] as String, item['subject'] as String), item['bucket']);
      }
      for (final item in (vectors['weighted'] as List).cast<Map<String, dynamic>>()) {
        expect(rolloutIncludes(item['id'] as String, item['subject'] as String, item['percent'] as int, level: item['level'] as int), item['included'], reason: '$item');
      }
    });

    test('积分等级加权：倍数 1 到 3 倍、等级越高进的越多且包含低等级的；放量 0 不论等级都不在，100 都在', () {
      final subjects = [for (var index = 0; index < 4000; index++) 'subject-$index'];
      Set<String> at(int level) => subjects.where((subject) => rolloutIncludes('feature', subject, 10, level: level)).toSet();
      expect(at(0).length / subjects.length, closeTo(0.10, 0.02));
      expect(at(5).length / subjects.length, closeTo(0.30, 0.03));
      for (var level = 1; level <= 5; level++) {
        expect(at(level).containsAll(at(level - 1)), isTrue);
      }
      expect(subjects.where((subject) => rolloutIncludes('feature', subject, 0, level: 5)), isEmpty);
      expect(subjects.every((subject) => rolloutIncludes('feature', subject, 100)), isTrue);
      expect(subjects.where((subject) => rolloutIncludes('feature', subject, 50, level: 5)).length, subjects.length, reason: '50% × 3 倍封顶到全部');
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

    test('积分等级的门槛 levels 可以没有；有就是从 0 起严格递增的六个数，读回来再写一样', () {
      expect(decodeRolloutConfig({'flags': <Object?>[]}).levels, isEmpty);
      final config = decodeRolloutConfig({'flags': <Object?>[], 'levels': [0, 500, 3000, 10000, 30000, 80000]});
      expect(config.levels, [0, 500, 3000, 10000, 30000, 80000]);
      expect(encodeRolloutConfig(decodeRolloutConfig(encodeRolloutConfig(config)))['levels'], config.levels);
      expect(encodeRolloutConfig(RolloutConfig.empty).containsKey('levels'), isFalse);
    });

    test('解锁 unlocks：编号、名字与条件，公开时刻带时区，下架只认 true；读回来再写一样', () {
      final config = decodeRolloutConfig({
        'flags': <Object?>[],
        'unlocks': [
          {'id': 'game.sudoku', 'title': '数独抢先玩', 'minLevel': 2, 'price': 300, 'publicAt': '2026-12-01T00:00:00+08:00'},
          {'id': 'toolbox.lab', 'title': '内测工具', 'percent': 10},
          {'id': 'toolbox.old', 'title': '下架的', 'retired': true},
        ],
      });
      final first = config.unlocks.first;
      expect(first.minLevel, 2);
      expect(first.price, 300);
      expect(first.publicAt, DateTime.utc(2026, 11, 30, 16));
      expect(first.isPublic(DateTime.utc(2026, 11, 30, 15)), isFalse);
      expect(first.isPublic(DateTime.utc(2026, 11, 30, 16)), isTrue);
      expect(config.unlocks.last.retired, isTrue);
      expect(jsonEncode(encodeRolloutConfig(decodeRolloutConfig(encodeRolloutConfig(config)))), jsonEncode(encodeRolloutConfig(config)));
      for (final bad in <Object?>[
        [{'id': 'a', 'title': 'A'}],
        [{'id': 'a', 'title': 'A', 'price': 1}, {'id': 'a', 'title': 'B', 'price': 2}],
        [{'id': 'a', 'title': '', 'price': 1}],
        [{'id': 'a', 'title': '名字超过二十个字名字超过二十个字名字超过二', 'price': 1}],
        [{'id': 'Bad Id', 'title': 'A', 'price': 1}],
        [{'id': 'a', 'title': 'A', 'minLevel': 6}],
        [{'id': 'a', 'title': 'A', 'price': 0}],
        [{'id': 'a', 'title': 'A', 'percent': 101}],
        [{'id': 'a', 'title': 'A', 'publicAt': '2026-12-01T00:00:00'}],
        [{'id': 'a', 'title': 'A', 'price': 1, 'retired': false}],
        [{'id': 'a', 'title': 'A', 'price': 1, 'secret': 1}],
        [for (var index = 0; index <= rolloutUnlockLimit; index++) {'id': 'u$index', 'title': 'U', 'price': 1}],
        'x',
      ]) {
        expect(() => decodeRolloutConfig({'flags': <Object?>[], 'unlocks': bad}), throwsFormatException, reason: '$bad');
      }
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
        {'flags': <Object?>[], 'levels': [0, 500, 3000]},
        {'flags': <Object?>[], 'levels': [1, 500, 3000, 10000, 30000, 80000]},
        {'flags': <Object?>[], 'levels': [0, 500, 500, 10000, 30000, 80000]},
        {'flags': <Object?>[], 'levels': [0, 500, 3000, 10000, 30000, 80000.5]},
        {'flags': <Object?>[], 'levels': 'x'},
      ]) {
        expect(() => decodeRolloutConfig(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('登记的功能开关编号合规、不重复（配置与服务器的点名都按它认）', () {
      expect(featureFlags.every((flag) => rolloutIdPattern.hasMatch(flag.id)), isTrue);
      expect(featureFlags.map((flag) => flag.id).toSet().length, featureFlags.length);
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
      final leveled = jsonDecode(await encodeRolloutFile(decodeRolloutConfig({'flags': <Object?>[], 'levels': [0, 500, 3000, 10000, 30000, 80000]}), [signing.rollout])) as Map<String, Object?>;
      await checkRolloutConfig(leveled, keys: signing.keys);
      expect(checkRolloutConfig({...leveled, 'levels': [0, 1, 3000, 10000, 30000, 80000]}, keys: signing.keys), throwsFormatException);
      expect(checkRolloutConfig({...leveled}..remove('levels'), keys: signing.keys), throwsFormatException);
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
      rollouts = Rollouts(platform: 'android', versionCode: 30, memory: memory, channel: 'alpha', accountId: () => accountId, feed: feed, now: () => now);
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

    test('回到前台就核对配置（至少隔 checkGap），带上次的版本号；没变不通知，失败照旧用上次的', () async {
      feed.next = decodeRolloutConfig({'flags': [{'id': 'challenge', 'percent': 100}]});
      await rollouts.refresh();
      await rollouts.refresh();
      expect(feed.fetches, 1);
      expect(feed.etags, [null], reason: '第一次取全量');
      now = now.add(Rollouts.checkGap);
      feed.unchanged = true;
      var notified = 0;
      rollouts.addListener(() => notified++);
      await rollouts.refresh();
      expect((feed.etags.last, notified, memory.etag), ('rev-1', 0, 'rev-1'));
      now = now.add(Rollouts.checkGap);
      feed
        ..unchanged = false
        ..next = null;
      await rollouts.refresh();
      expect(feed.fetches, 3);
      expect(rollouts.enabled('challenge', fallback: false), isTrue);
    });

    // 人工决策见 domain/rollout.dart 的 RolloutSignals（11-20 灰度改了立即生效）。
    test('回复头里的配置版本号变了马上重新取；同一个版本号只触发一次；同意协议与政策（第一次 refresh）之前不动', () async {
      final signals = RolloutSignals();
      final watched = Rollouts(platform: 'android', versionCode: 30, memory: memory, channel: 'alpha', accountId: () => null, feed: feed, signals: signals, now: () => now);
      feed.next = decodeRolloutConfig({'flags': [{'id': 'challenge', 'percent': 0}]});
      signals.observe({rolloutConfigHeader: 'rev-0'});
      await pumpEventQueue();
      expect(feed.fetches, 0, reason: '还没同意');
      await watched.refresh();
      signals.observe({rolloutConfigHeader: 'rev-1'});
      await pumpEventQueue();
      expect(feed.fetches, 1, reason: '和本机记的一样');
      feed
        ..next = decodeRolloutConfig({'flags': [{'id': 'challenge', 'percent': 100}]})
        ..served = 'rev-2';
      signals.observe({rolloutConfigHeader: 'rev-2', 'etag': 'x'});
      await pumpEventQueue();
      expect((feed.fetches, feed.etags.last, memory.etag), (2, 'rev-1', 'rev-2'));
      expect(watched.enabled('challenge', fallback: false), isTrue, reason: '用着的时候就生效');
      feed.served = 'rev-3';
      signals.observe({rolloutConfigHeader: 'rev-9'});
      signals.observe({rolloutConfigHeader: 'rev-9'});
      await pumpEventQueue();
      expect(feed.fetches, 3, reason: '取回来的还不是 rev-9（中转几个实例不同步），也不再为它来回');
      watched.dispose();
    });

    test('登录着应用账号时同一时机取积分等级：等级加权进批次；只因等级进的降级后照旧在里面，放量 0 仍关', () async {
      final candidates = Iterable<String>.generate(2000, (index) => 'subject-$index');
      final lifted = candidates.firstWhere((subject) => !rolloutIncludes('feature', subject, 10) && rolloutIncludes('feature', subject, 10, level: 5));
      var level = 5;
      var asked = 0;
      final leveled = Rollouts(platform: 'android', versionCode: 30, memory: memory, channel: 'alpha', accountId: () => accountId, feed: feed, level: () async => (asked++, level).$2, now: () => now);
      feed.next = decodeRolloutConfig({'flags': [{'id': 'feature', 'percent': 10}]});
      accountId = lifted;
      await leveled.refresh();
      expect(asked, 1);
      expect(memory.levelOf(lifted), 5);
      expect(leveled.enabled('feature', fallback: false), isTrue);
      await pumpEventQueue();
      expect(memory.joined(lifted, 'feature'), isTrue);
      level = 0;
      now = now.add(Rollouts.refreshGap);
      await leveled.refresh();
      expect(memory.levelOf(lifted), 0);
      expect(leveled.enabled('feature', fallback: false), isTrue, reason: '降级不踢出');
      now = now.add(Rollouts.refreshGap);
      feed.next = decodeRolloutConfig({'flags': [{'id': 'feature', 'percent': 0}]});
      await leveled.refresh();
      expect(leveled.enabled('feature', fallback: true), isFalse, reason: '一键关停不受等级影响');
    });

    test('仅本机时不取等级、按 Lv0 判定，已经因等级进了的批次照旧；删了数据记着的等级归零', () async {
      final candidates = Iterable<String>.generate(2000, (index) => 'subject-$index');
      final lifted = candidates.firstWhere((subject) => !rolloutIncludes('feature', subject, 10) && rolloutIncludes('feature', subject, 10, level: 5));
      final other = candidates.firstWhere((subject) => subject != lifted && !rolloutIncludes('other', subject, 10) && rolloutIncludes('other', subject, 10, level: 5));
      var asked = 0, levelsOn = true;
      final leveled = Rollouts(platform: 'android', versionCode: 30, memory: memory, channel: 'alpha', accountId: () => accountId, feed: feed, level: () async => (asked++, 5).$2, levelsOn: () => levelsOn, now: () => now);
      feed.next = decodeRolloutConfig({'flags': [{'id': 'feature', 'percent': 10}, {'id': 'other', 'percent': 10}]});
      accountId = lifted;
      await leveled.refresh();
      expect(leveled.enabled('feature', fallback: false), isTrue);
      await pumpEventQueue();
      levelsOn = false;
      now = now.add(Rollouts.refreshGap);
      await leveled.refresh();
      expect(asked, 1, reason: '关着不取等级');
      expect(leveled.enabled('feature', fallback: false), isTrue, reason: '已经进了的照旧');
      accountId = other;
      await memory.saveLevel(other, 5);
      expect(leveled.enabled('other', fallback: false), isFalse, reason: '关着按 Lv0');
      levelsOn = true;
      expect(leveled.enabled('other', fallback: false), isTrue);
      await leveled.forgetLevel();
      expect(memory.levelOf(other), 0);
    });

    test('没登录应用账号不取等级；取不到照旧用记着的', () async {
      var asked = 0;
      int? level = 3;
      final leveled = Rollouts(platform: 'android', versionCode: 30, memory: memory, channel: 'alpha', accountId: () => accountId, feed: feed, level: () async => (asked++, level).$2, now: () => now);
      feed.next = RolloutConfig.empty;
      await leveled.refresh();
      expect(asked, 0);
      accountId = 'AAAAAAAAAAAAAAAAAAAAAB';
      now = now.add(Rollouts.refreshGap);
      await leveled.refresh();
      expect(memory.levelOf('AAAAAAAAAAAAAAAAAAAAAB'), 3);
      level = null;
      now = now.add(Rollouts.refreshGap);
      await leveled.refresh();
      expect(asked, 2);
      expect(memory.levelOf('AAAAAAAAAAAAAAAAAAAAAB'), 3);
    });

    test('没配中转时不联网，开关按默认值', () async {
      final offline = Rollouts(platform: 'android', versionCode: 30, memory: FileRolloutMemory.memory(), channel: 'alpha', accountId: () => null, now: () => now);
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

    test('等级与只因等级进的批次跟着主体存：换了主体从头记，批次最多 rolloutRuleLimit 个、旧的先丢；格式不对的当没记过', () async {
      final file = File('${directory.path}/rollout.json');
      final memory = await FileRolloutMemory.open(file);
      await memory.saveLevel('account-a', 4);
      await memory.join('account-a', 'feature');
      final again = await FileRolloutMemory.open(file);
      expect(again.levelOf('account-a'), 4);
      expect(again.joined('account-a', 'feature'), isTrue);
      expect(again.levelOf('account-b'), 0);
      expect(again.joined('account-b', 'feature'), isFalse);
      await again.join('account-b', 'other');
      expect(again.levelOf('account-a'), 0);
      expect(again.joined('account-a', 'feature'), isFalse);
      for (var index = 0; index <= rolloutRuleLimit; index++) {
        await again.join('account-b', 'f$index');
      }
      expect(again.joined('account-b', 'other'), isFalse);
      expect(again.joined('account-b', 'f$rolloutRuleLimit'), isTrue);
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect((json['joined'] as List).length, rolloutRuleLimit);
      await file.writeAsString(jsonEncode({...json, 'level': 9}));
      final bad = await FileRolloutMemory.open(file);
      expect(bad.installId, again.installId);
      expect(bad.levelOf('account-b'), 0);
      expect(bad.joined('account-b', 'f1'), isFalse);
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

  group('第 2 版：条件、参数与点名', () {
    final conditional = {
      'id': 'game.flash2',
      'percent': 100,
      'from': '2026-11-14T00:00:00+08:00',
      'until': '2026-11-20T00:00:00Z',
      'platforms': ['android'],
      'channels': ['alpha'],
      'minVersion': 29,
      'maxVersion': 40,
      'minLevel': 2,
      'minAccountDays': 7,
      'params': {'limit': 3, 'ratio': 0.5, 'label': '新版', 'strict': true},
    };

    test('条件与参数读回来再写一样；旧版视图去掉带新字段的开关，等级与解锁照旧', () {
      final config = decodeRolloutConfig({
        'version': 2,
        'flags': [conditional, {'id': 'plain', 'percent': 10}],
        'levels': [0, 500, 3000, 10000, 30000, 80000],
      });
      final rule = config.rules['game.flash2']!;
      expect(rule.from, DateTime.utc(2026, 11, 13, 16));
      expect(rule.platforms, {'android'});
      expect(rule.params, {'limit': 3, 'ratio': 0.5, 'label': '新版', 'strict': true});
      expect(rule.conditional, isTrue);
      expect(config.rules['plain']!.conditional, isFalse);
      expect(jsonEncode(encodeRolloutConfig(decodeRolloutConfig(encodeRolloutConfig(config)))), jsonEncode(encodeRolloutConfig(config)));
      final legacy = config.legacy;
      expect(legacy.rules.keys, ['plain']);
      expect(legacy.levels, config.levels);
      // 旧版本的解码：开关只有 id 加 percent 或 stages，顶层不带 version。
      final legacyJson = encodeRolloutConfig(legacy);
      expect(legacyJson.keys, ['flags', 'levels']);
      expect((legacyJson['flags']! as List).single, {'id': 'plain', 'percent': 10});
    });

    test('条件的外部输入：时刻不带时区、窗口倒置、平台不认识、版本区间倒置、等级越界、参数名或值不合法、多出来的字段都不认', () {
      Map<String, Object?> flag(Map<String, Object?> extra) => {'flags': [{'id': 'x', 'percent': 1, ...extra}]};
      for (final bad in [
        flag({'from': '2026-11-14T00:00:00'}),
        flag({'from': '2026-11-15T00:00:00Z', 'until': '2026-11-14T00:00:00Z'}),
        flag({'until': 5}),
        flag({'platforms': ['windows']}),
        flag({'platforms': <String>[]}),
        flag({'channels': ['Bad Channel']}),
        flag({'minVersion': 40, 'maxVersion': 29}),
        flag({'minVersion': 0}),
        flag({'minLevel': pointsLevelCount}),
        flag({'minAccountDays': 0}),
        flag({'params': <String, Object?>{}}),
        flag({'params': {'Bad': 1}}),
        flag({'params': {'list': <int>[]}}),
        flag({'params': {'text': 'x' * (rolloutParamTextMax + 1)}}),
        flag({'params': {for (var index = 0; index <= rolloutParamLimit; index++) 'k$index': index}}),
        flag({'extra': 1}),
        {'version': 3, 'flags': <Object?>[]},
      ]) {
        expect(() => decodeRolloutConfig(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('两份签名：第 2 版载荷是整份配置，第 1 版只放没有新字段的开关；核对挡住第 1 版里带条件的开关', () async {
      final signing = await TestSigning.create();
      final config = decodeRolloutConfig({'flags': [conditional, {'id': 'plain', 'percent': 10}], 'unlocks': [{'id': 'game.sudoku', 'title': '数独', 'price': 100}]});
      final flags = jsonDecode(await encodeFlagsFile(config, [signing.rollout])) as Map<String, Object?>;
      expect(flags.keys, ['version', 'envelope']);
      expect((await checkFlagsConfig(flags, keys: signing.keys)).rules.keys, ['game.flash2', 'plain']);
      final legacy = jsonDecode(await encodeRolloutFile(config, [signing.rollout])) as Map<String, Object?>;
      await checkRolloutConfig(legacy, keys: signing.keys);
      expect((await decodeSignedRolloutConfig(legacy, keys: signing.keys)).rules.keys, ['plain']);
      final plain = encodeRolloutConfig(config);
      final forged = {...plain, 'envelope': await signing.seal(plain, SignedContent.rollout, [signing.rollout])};
      await expectLater(checkRolloutConfig(forged, keys: signing.keys), throwsFormatException);
      await expectLater(checkFlagsConfig({...flags, 'flags': <Object?>[]}, keys: signing.keys), throwsFormatException);
      await expectLater(checkFlagsConfig({'version': 2, 'envelope': legacy['envelope']}, keys: signing.keys), completes, reason: '第 1 版的载荷也是合法的第 2 版');
    });

    test('拉取：先拉第 2 版；中转还没放第 2 版或是旧中转（404）退回第 1 版；第 2 版外形不对报错', () async {
      final signing = await TestSigning.create();
      final config = decodeRolloutConfig({'flags': [conditional, {'id': 'plain', 'percent': 10}]});
      final flags = await encodeFlagsFile(config, [signing.rollout]);
      final legacy = await encodeRolloutFile(config, [signing.rollout]);
      Future<RolloutConfig> fetch(Map<String, (String, int)> replies) async {
        final paths = <String>[];
        return (await RelayRolloutFeed('https://relay.invalid', keys: signing.keys, client: MockClient((request) async {
          paths.add(request.url.path);
          final (body, status) = replies[request.url.path]!;
          return http.Response.bytes(utf8.encode(body), status);
        })).fetch()).config!;
      }

      expect((await fetch({'/v1/app/flags': (flags, 200)})).rules.keys, ['game.flash2', 'plain']);
      expect((await fetch({'/v1/app/flags': ('{"version":2,"envelope":null}', 200), '/v1/app/rollout': (legacy, 200)})).rules.keys, ['plain']);
      expect((await fetch({'/v1/app/flags': ('{"code":"NOT_FOUND"}', 404), '/v1/app/rollout': (legacy, 200)})).rules.keys, ['plain']);
      await expectLater(fetch({'/v1/app/flags': ('{"version":1,"envelope":null}', 200)}), throwsA(isA<RolloutException>()));
      await expectLater(fetch({'/v1/app/flags': ('{"code":"INTERNAL"}', 500)}), throwsA(isA<RolloutException>()));
    });

    test('拉取的条件请求：带上次的版本号（If-None-Match），304 给出没变；全量回复记下 ETag', () async {
      final signing = await TestSigning.create();
      final flags = await encodeFlagsFile(decodeRolloutConfig({'flags': [{'id': 'plain', 'percent': 10}]}), [signing.rollout]);
      final sent = <String?>[];
      var notModified = false;
      final feed = RelayRolloutFeed('https://relay.invalid', keys: signing.keys, client: MockClient((request) async {
        sent.add(request.headers['if-none-match']);
        return notModified ? http.Response('', 304, headers: {'etag': '"rev-1"'}) : http.Response.bytes(utf8.encode(flags), 200, headers: {'etag': '"rev-1"'});
      }));
      final full = await feed.fetch();
      expect(full.config?.rules.keys, ['plain']);
      expect(full.etag, 'rev-1');
      notModified = true;
      final same = await feed.fetch(etag: 'rev-1');
      expect((same.config, same.etag), (null, 'rev-1'));
      expect(sent, [null, '"rev-1"']);
    });

    group('判定', () {
      late DateTime now;
      late String? accountId;
      late _Feed feed;
      late FileRolloutMemory memory;
      late RolloutTargets? remote;
      final created = DateTime.utc(2026, 11, 1);
      RolloutTargets reply(List<RolloutTarget> flags) => RolloutTargets(flags: flags, accountCreatedAt: created);
      late int asked;
      late List<String?> etags;
      late RolloutSignals signals;
      var targetsUnchanged = false;
      var targetsServed = 't-1';
      Rollouts rollouts({String platform = 'android', String channel = 'alpha', int versionCode = 30, int level = 2}) => Rollouts(
        memory: memory,
        channel: channel,
        platform: platform,
        versionCode: versionCode,
        accountId: () => accountId,
        feed: feed,
        level: () async => level,
        targets: (etag) async {
          asked++;
          etags.add(etag);
          return switch (remote) {
            final RolloutTargets targets? when !targetsUnchanged => RolloutTargetsFetch(targets, etag: targetsServed),
            final RolloutTargets _? => RolloutTargetsFetch(null, etag: etag),
            null => null,
          };
        },
        signals: signals,
        now: () => now,
      );
      setUp(() {
        now = DateTime.utc(2026, 11, 15);
        accountId = 'account-a';
        feed = _Feed()..next = decodeRolloutConfig({'flags': [conditional]});
        memory = FileRolloutMemory.memory();
        remote = reply(const []);
        asked = 0;
        etags = [];
        signals = RolloutSignals();
        targetsUnchanged = false;
        targetsServed = 't-1';
      });
      const flag = FeatureFlag('game.flash2', fallback: false);

      test('条件都满足才按比例开，命中时读得到参数；时间窗外、平台渠道不对、版本号不在区间、等级不够都关', () async {
        final on = rollouts();
        await on.refresh();
        expect(on.isOn(flag), isTrue);
        expect(on.param(flag, 'limit'), 3);
        expect(on.param(flag, 'missing'), isNull);
        expect(rollouts(platform: 'ios').isOn(flag), isFalse);
        expect(rollouts(channel: 'beta').isOn(flag), isFalse);
        expect(rollouts(versionCode: 28).isOn(flag), isFalse);
        expect(rollouts(versionCode: 41).isOn(flag), isFalse);
        expect(rollouts(platform: 'ios').param(flag, 'limit'), isNull, reason: '没开不给参数');
        now = DateTime.utc(2026, 11, 20);
        expect(on.isOn(flag), isFalse, reason: '过了 until 全关');
        now = DateTime.utc(2026, 11, 13, 15, 59);
        expect(on.isOn(flag), isFalse, reason: 'from 之前关');
      });

      test('账号建立的天数按问点名时一起拿到的建立时刻算：不够关；没登录应用账号、还没问到都不满足', () async {
        // 只带这一个条件，免得被时间窗、平台或等级挡住。
        feed.next = decodeRolloutConfig({'flags': [{'id': 'game.flash2', 'percent': 100, 'minAccountDays': 7}]});
        remote = null;
        final aged = rollouts(level: 0);
        await aged.refresh();
        expect(memory.config.rules['game.flash2']!.minAccountDays, 7);
        expect(aged.isOn(flag), isFalse, reason: '还没问到建立时刻');
        now = now.add(Rollouts.refreshGap);
        remote = reply(const []);
        await aged.refresh();
        expect(aged.isOn(flag), isTrue, reason: '建立 14 天，要求 7 天');
        now = created.add(const Duration(days: 6, hours: 23));
        expect(aged.isOn(flag), isFalse, reason: '不满 7 天');
        now = created.add(const Duration(days: 7));
        expect(aged.isOn(flag), isTrue, reason: '刚满 7 天');
        accountId = null;
        expect(aged.isOn(flag), isFalse, reason: '没登录应用账号');
      });

      test('等级条件按记着的等级：等级不够关，仅本机按 Lv0', () async {
        final low = rollouts(level: 1);
        await low.refresh();
        expect(low.isOn(flag), isFalse);
        final off = Rollouts(memory: memory, channel: 'alpha', platform: 'android', versionCode: 30, accountId: () => accountId, feed: feed, level: () async => 5, levelsOn: () => false, now: () => now);
        await memory.saveLevel('account-a', 5);
        expect(off.isOn(flag), isFalse);
      });

      test('点名的不看比例与条件、只看到期时刻；撤销（问到空列表）就关；问不到照旧用记着的；没登录不问也不用', () async {
        feed.next = decodeRolloutConfig({'flags': [{...conditional, 'percent': 0}]});
        remote = reply([RolloutTarget('game.flash2', until: DateTime.utc(2026, 11, 16))]);
        final ios = rollouts(platform: 'ios', level: 0);
        await ios.refresh();
        expect(asked, 1);
        expect(ios.isOn(flag), isTrue, reason: '点名不看平台、等级与比例');
        expect(ios.param(flag, 'limit'), 3, reason: '点名开的也读配置里的参数');
        now = DateTime.utc(2026, 11, 16);
        expect(ios.isOn(flag), isFalse, reason: '点名到期');
        now = DateTime.utc(2026, 11, 15).add(Rollouts.refreshGap);
        remote = null;
        await ios.refresh();
        expect(ios.isOn(flag), isTrue, reason: '问不到照旧用记着的');
        now = now.add(Rollouts.refreshGap);
        remote = reply(const []);
        await ios.refresh();
        expect(ios.isOn(flag), isFalse, reason: '撤销');
        accountId = null;
        now = now.add(Rollouts.refreshGap);
        remote = reply([const RolloutTarget('game.flash2')]);
        final before = asked;
        await ios.refresh();
        expect(asked, before, reason: '没登录不问');
        expect(ios.isOn(flag), isFalse);
      });

      test('点名回到前台带版本号核对，没变不动；回复头里的点名版本变了马上问一次全量，同一个只问一次', () async {
        feed.next = decodeRolloutConfig({'flags': [{...conditional, 'percent': 0}]});
        final watched = rollouts(level: 0);
        await watched.refresh();
        expect(etags, [null]);
        expect(memory.targetsEtagOf('account-a'), 't-1');
        expect(watched.isOn(flag), isFalse);
        now = now.add(Rollouts.checkGap);
        targetsUnchanged = true;
        await watched.refresh();
        expect(etags.last, 't-1');
        targetsUnchanged = false;
        targetsServed = 't-2';
        remote = reply([const RolloutTarget('game.flash2')]);
        signals.observe({rolloutTargetsHeader: '1795000000000'});
        await pumpEventQueue();
        expect((etags.last, memory.targetsEtagOf('account-a')), (null, 't-2'), reason: '回复头触发的问全量');
        expect(watched.isOn(flag), isTrue, reason: '点名了马上就开');
        final before = asked;
        signals.observe({rolloutTargetsHeader: '1795000000000'});
        await pumpEventQueue();
        expect(asked, before);
        accountId = null;
        signals.observe({rolloutTargetsHeader: '1795000000001'});
        await pumpEventQueue();
        expect(asked, before, reason: '没登录不问');
        watched.dispose();
      });

      test('配置与点名的版本号记在本机，重开还在；换了主体点名的版本号从头记；格式不对的当没记过', () async {
        final directory = await Directory.systemTemp.createTemp('rollout_etag');
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/rollout.json');
        final saved = await FileRolloutMemory.open(file);
        await saved.save(RolloutConfig.empty, now, etag: 'rev-1');
        await saved.saveTargets('account-a', reply(const []), etag: '1795000000000');
        final reopened = await FileRolloutMemory.open(file);
        expect((reopened.etag, reopened.targetsEtagOf('account-a'), reopened.targetsEtagOf('account-b')), ('rev-1', '1795000000000', null));
        await reopened.saveLevel('account-b', 1);
        expect(reopened.targetsEtagOf('account-a'), isNull);
        final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
        await file.writeAsString(jsonEncode({...raw, 'etag': '"带引号"'}));
        expect((await FileRolloutMemory.open(file)).etag, isNull);
      });

      test('点名跟着主体存在本机：换了账号从头记；格式不对的当没问过', () async {
        final directory = await Directory.systemTemp.createTemp('rollout_targets');
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/rollout.json');
        final stored = await FileRolloutMemory.open(file);
        await stored.saveTargets('account-a', RolloutTargets(flags: [RolloutTarget('a.one', until: DateTime.utc(2026, 12, 1)), const RolloutTarget('a.two')], accountCreatedAt: DateTime.utc(2026, 10, 1)));
        final again = await FileRolloutMemory.open(file);
        expect(again.targetsOf('account-a').map((target) => (target.id, target.until)), [('a.one', DateTime.utc(2026, 12, 1)), ('a.two', null)]);
        expect(again.accountCreatedOf('account-a'), DateTime.utc(2026, 10, 1));
        expect(again.targetsOf('account-b'), isEmpty);
        expect(again.accountCreatedOf('account-b'), isNull);
        await again.saveLevel('account-b', 1);
        expect(again.targetsOf('account-a'), isEmpty);
        expect(again.accountCreatedOf('account-b'), isNull, reason: '换了主体从头记');
        await again.saveTargets('account-a', RolloutTargets(flags: [const RolloutTarget('a.one')], accountCreatedAt: DateTime.utc(2026, 10, 1)));
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        await file.writeAsString(jsonEncode({...json, 'targets': {'flags': [{'id': 'Bad Id', 'until': null}], 'accountCreatedAt': '2026-10-01T00:00:00.000Z'}}));
        final bad = await FileRolloutMemory.open(file);
        expect(bad.targetsOf('account-a'), isEmpty);
        expect(bad.accountCreatedOf('account-a'), isNull);
        expect(bad.installId, again.installId);
      });
    });

    test('点名的中转客户端：用应用账号的设备密钥签名问 /v1/flags/mine；没这把密钥或账号不在了为空，连不上与看不懂的回复报错', () async {
      final vault = MemoryAppAccountVault();
      final relay = _Relay();
      final client = RelayFlagTargetClient(vault: vault, transport: relay);
      const ref = AppAccountRef(accountId: 'AAAAAAAAAAAAAAAAAAAAAA', slot: appAccountSlot);
      expect(await client.mine(ref), isNull);
      expect(relay.requests, isEmpty, reason: '没有密钥不发请求');
      final key = await RelayIdentity.fromSeeds(List<int>.generate(32, (index) => index + 1), List<int>.generate(32, (index) => index + 33));
      await vault.write(appAccountSlot, AppAccountKey(identity: key, accountId: 'AAAAAAAAAAAAAAAAAAAAAA'));
      relay.reply = const RelayResponse(200, {'flags': [{'id': 'game.flash2', 'until': '2026-12-01T00:00:00.000Z'}], 'accountCreatedAt': '2026-11-01T08:00:00.000Z'}, headers: {'etag': '"0"'});
      final fetched = (await client.mine(ref))!;
      final targets = fetched.targets!;
      expect(fetched.etag, '0');
      expect(relay.requests.last.$2.containsKey('if-none-match'), isFalse);
      expect(relay.requests.last.$1, 'GET /v1/flags/mine');
      expect(relay.requests.last.$2['x-sxd-device'], key.deviceId);
      expect(relay.requests.last.$2.containsKey('x-sxd-signature'), isTrue);
      expect(targets.flags.single.until, DateTime.utc(2026, 12, 1));
      expect(targets.accountCreatedAt, DateTime.utc(2026, 11, 1, 8));
      // 条件请求：带着版本号问，没变中转回 304。
      relay.reply = const RelayResponse(304, {}, headers: {'etag': '"0"'});
      final same = (await client.mine(ref, etag: '0'))!;
      expect((same.targets, same.etag, relay.requests.last.$2['if-none-match']), (null, '0', '"0"'));
      relay.reply = const RelayResponse(404, {'code': 'ACCOUNT_NOT_FOUND'});
      expect(await client.mine(ref), isNull);
      relay.reply = const RelayResponse(429, {'code': 'RATE_LIMITED', 'retryAfter': 60});
      await expectLater(client.mine(ref), throwsA(isA<RolloutException>()));
      relay.reply = const RelayResponse(200, {'flags': [{'id': 'Bad Id', 'until': null}], 'accountCreatedAt': '2026-11-01T08:00:00.000Z'});
      await expectLater(client.mine(ref), throwsA(isA<RolloutException>()));
    });

    test('点名列表是外部输入：编号合规、不重复、到期时刻与账号建立时刻带时区、不超过上限', () {
      const at = '2026-11-01T00:00:00.000Z';
      final decoded = decodeRolloutTargets({'flags': [{'id': 'a.b', 'until': '2026-12-01T00:00:00.000Z'}, {'id': 'c', 'until': null}], 'accountCreatedAt': at});
      expect(decoded.flags.map((target) => target.id), ['a.b', 'c']);
      expect(decoded.accountCreatedAt, DateTime.utc(2026, 11));
      for (final bad in <Object?>[
        null,
        {'flags': 'x', 'accountCreatedAt': at},
        {'flags': <Object?>[]},
        {'flags': <Object?>[], 'accountCreatedAt': '2026-11-01T00:00:00'},
        {'flags': [{'id': 'Bad Id', 'until': null}], 'accountCreatedAt': at},
        {'flags': [{'id': 'a', 'until': null}, {'id': 'a', 'until': null}], 'accountCreatedAt': at},
        {'flags': [{'id': 'a', 'until': '2026-12-01T00:00:00'}], 'accountCreatedAt': at},
        {'flags': [{'id': 'a'}], 'accountCreatedAt': at},
        {'flags': [{'id': 'a', 'until': 1}], 'accountCreatedAt': at},
        {'flags': [for (var index = 0; index <= rolloutTargetLimit; index++) {'id': 'f$index', 'until': null}], 'accountCreatedAt': at},
      ]) {
        expect(() => decodeRolloutTargets(bad), throwsFormatException, reason: '$bad');
      }
    });
  });
}

class _Relay implements RelayTransport {
  RelayResponse reply = const RelayResponse(200, {});
  final requests = <(String, Map<String, String>)>[];
  @override
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout, int? limit, bool background = false}) async {
    requests.add(('$method $pathWithQuery', headers));
    return reply;
  }
}
