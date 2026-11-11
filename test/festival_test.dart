import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/application/app_moments.dart';
import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/application/festivals.dart';
import 'package:superxd/device/relay_reward_client.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/developer_note.dart';
import 'package:superxd/domain/festival.dart';
import 'package:superxd/local/developer_note_memory.dart';
import 'package:superxd/local/festival_memory.dart';
import 'package:superxd/page/festival/festival_reward.dart';
import 'package:superxd/page/festival/festival_stage.dart';
import 'package:superxd/social/festival_pass.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';

import 'fake_relay.dart';

// 合成的抽签：按给定结果回，calls 记次数；gate 不为空时等它完成才回（测并发只抽一次）。
class FakeRewardClient implements FestivalRewardClient {
  FakeRewardClient(this.result);
  FestivalDraw Function(String occasion) result;
  Object? failure;
  Completer<void>? gate;
  final requests = <({String campaign, int activeDays})>[];

  @override
  Future<FestivalDraw> draw(String campaign, {required String occasion, required int activeDays}) async {
    requests.add((campaign: campaign, activeDays: activeDays));
    await gate?.future;
    if (failure case final failure?) throw failure;
    return result(occasion);
  }
}

// 合成的抽奖身份：只记调用；failure 不为空时登记与撤下都抛它；gate 不为空时登记等它完成。
class FakePass implements FestivalPass {
  final calls = <String>[];
  Object? failure;
  Completer<void>? gate;

  @override
  Future<void> enroll() async {
    calls.add('enroll');
    await gate?.future;
    if (failure case final failure?) throw failure;
  }

  @override
  Future<Map<String, Object?>> post(String path, Map<String, Object?> payload) => throw UnimplementedError();

  @override
  Future<void> retire() async {
    calls.add('retire');
    if (failure case final failure?) throw failure;
  }
}

// 抽签的假中转：设备登记与删除交给按协议 v1 验签的 FakeRelay；抽签同样按登记过的签名公钥验签（没登记回 UNAUTHORIZED），再按 result 回。
class _RewardRelay implements RelayTransport {
  _RewardRelay(this.relay);
  final FakeRelay relay;
  final draws = <({String device, String path, Map<String, Object?> body})>[];
  Map<String, Object?> result = {'result': 'missed', 'prize': null};

  @override
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout, int? limit, bool background = false}) async {
    if (!pathWithQuery.startsWith('/v1/rewards/')) return relay.handle(method, pathWithQuery, headers, body, timeout: timeout);
    final failure = relay.failNext;
    if (failure != null) {
      relay.failNext = null;
      throw failure;
    }
    final device = headers['x-sxd-device']!, key = relay.devices[device]?.sign;
    final canonical = requestCanonical(method, pathWithQuery, headers['x-sxd-time']!, headers['x-sxd-nonce']!, body ?? const []);
    if (key == null || !await verifySignature(key, canonical, decodeBase64UrlNoPad(headers['x-sxd-signature']!))) return const RelayResponse(401, {'code': RelayCode.unauthorized});
    draws.add((device: device, path: pathWithQuery, body: (jsonDecode(utf8.decode(body!)) as Map).cast<String, Object?>()));
    return RelayResponse(200, result);
  }
}

FestivalPrize prize(String occasion, {FestivalPrizeKind kind = FestivalPrizeKind.password, String content = '88662027', bool revealed = false}) =>
    FestivalPrize(occasion: occasion, kind: kind, content: content, note: '附言', wonAt: DateTime.utc(2027, 2, 6), revealed: revealed);

// 校园时区某天中午。
DateTime campusNoon(int month, int day) => DateTime.utc(2027, month, day, 4);

void main() {
  // 校园时区 2027-02-06 12:00（春节当天中午）。
  final noon = campusNoon(2, 6);
  const spring = FestivalOccasion(id: 'spring-2027', name: '新春快乐', from: '2027-02-06', to: '2027-02-08', campaign: 'spring-2027');
  const lantern = FestivalOccasion(id: 'lantern-2027', name: '元宵快乐', from: '2027-02-20', to: '2027-02-20');
  const enrolled = FestivalRecord(pass: FestivalPassState.enrolled);

  group('规则', () {
    test('节日按校园日含两端；活跃天数只算近 30 天；奖品在节日结束后再留 3 天', () {
      expect([for (final day in ['2027-02-05', '2027-02-06', '2027-02-08', '2027-02-09']) spring.on(day)], [false, true, true, false]);
      expect(festivalActiveDays({'2027-01-07', '2027-01-08', '2027-02-06', '2027-02-07'}, '2027-02-06'), {'2027-01-08', '2027-02-06'});
      expect(festivalPrizeKept(prize('spring-2027'), [spring], '2027-02-11'), isTrue);
      expect(festivalPrizeKept(prize('spring-2027'), [spring], '2027-02-12'), isFalse);
      expect(festivalPrizeKept(prize('gone'), [spring], '2027-02-06'), isFalse);
    });

    test('抽奖身份只在有抽奖的节日开始前 7 天到结束（含两端）之间要有；没有抽奖的节日不算', () {
      expect([for (final day in ['2027-01-29', '2027-01-30', '2027-02-08', '2027-02-09']) festivalPassNeeded([spring, lantern], day)], [false, true, true, false]);
      expect(festivalPassNeeded([lantern], '2027-02-20'), isFalse);
      expect(festivalPassNeeded(const [], '2027-02-06'), isFalse);
    });

    test('抽签结果是外部输入：认不出的结果、种类与超长内容都拒绝', () {
      final now = DateTime.utc(2027);
      expect(parseFestivalDraw({'result': 'missed', 'prize': null}, occasion: 'a', now: now), isA<FestivalMissed>());
      expect(parseFestivalDraw({'result': 'closed', 'prize': null}, occasion: 'a', now: now), isA<FestivalClosed>());
      final won = parseFestivalDraw({'result': 'won', 'prize': {'kind': 'qrcode', 'content': ' https://qr.alipay.com/x ', 'note': ''}}, occasion: 'a', now: now);
      expect((won as FestivalWon).prize.kind, FestivalPrizeKind.qrCode);
      expect(won.prize.content, 'https://qr.alipay.com/x');
      for (final bad in [
        {'result': 'won', 'prize': {'kind': 'cash', 'content': 'x', 'note': ''}},
        {'result': 'won', 'prize': {'kind': 'password', 'content': ' ', 'note': ''}},
        {'result': 'won', 'prize': {'kind': 'password', 'content': 'x' * 1025, 'note': ''}},
        {'result': 'won'},
        {'result': 'lucky'},
      ]) {
        expect(() => parseFestivalDraw(bad, occasion: 'a', now: now), throwsFormatException);
      }
    });
  });

  group('本机记录', () {
    test('写下再读回；播过与抽过只留最近 20 次；坏的项丢掉、坏文件当没有记录；旧版本的参与号不认也不写', () async {
      final directory = await Directory.systemTemp.createTemp('festival');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/festival.json');
      final memory = await FileFestivalMemory.open(file);
      await memory.save(FestivalRecord(
        pass: FestivalPassState.enrolled,
        activeDays: {'2027-02-06'},
        played: [for (var index = 0; index < 25; index++) 'p$index'],
        drawn: ['spring-2027'],
        prizes: [prize('spring-2027')],
      ));
      final record = (await FileFestivalMemory.open(file)).record;
      expect(record.pass, FestivalPassState.enrolled);
      expect(record.played, [for (var index = 5; index < 25; index++) 'p$index']);
      expect(record.prizes.single.content, '88662027');
      final json = jsonDecode(await file.readAsString()) as Map;
      (json['prizes'] as List).add({'occasion': 'x', 'kind': 'cash', 'content': 'y', 'note': '', 'wonAt': 'bad', 'revealed': false});
      json['pass'] = 'lucky';
      await file.writeAsString(jsonEncode(json));
      final cleaned = (await FileFestivalMemory.open(file)).record;
      expect(cleaned.pass, FestivalPassState.none);
      expect(cleaned.prizes, hasLength(1));
      // 旧版本写的文件：有 participant、没有 pass。照常读出其余各项，下次写就不再有参与号。
      await file.writeAsString(jsonEncode({'participant': 'AAAAAAAAAAAAAAAAAAAAAA', 'activeDays': ['2027-02-06'], 'played': ['spring-2027'], 'drawn': <Object?>[], 'prizes': <Object?>[]}));
      final legacy = await FileFestivalMemory.open(file);
      expect(legacy.record.pass, FestivalPassState.none);
      expect(legacy.record.played, ['spring-2027']);
      await legacy.save(legacy.record);
      expect(jsonDecode(await file.readAsString()), isNot(contains('participant')));
      await file.writeAsString('{坏');
      expect((await FileFestivalMemory.open(file)).record.played, isEmpty);
    });
  });

  group('编排（Festivals）', () {
    Festivals festivals({FestivalRewardClient? client, FestivalPass? pass, FestivalMemory? memory, DateTime? now}) =>
        Festivals(occasions: const [spring, lantern], memory: memory ?? FileFestivalMemory.memory(enrolled), pass: pass ?? FakePass(), client: client, clock: () => now ?? noon);

    test('今天在过、没播过的才该播；播过就不再播；不在节日里没有', () async {
      final subject = festivals();
      expect(subject.due?.id, 'spring-2027');
      await subject.markPlayed(spring);
      expect(subject.due, isNull);
      expect(festivals(now: DateTime.utc(2027, 2, 10)).due, isNull);
    });

    test('活跃天数：同一天只记一次，抽签时报近 30 天的天数', () async {
      final memory = FileFestivalMemory.memory(const FestivalRecord(pass: FestivalPassState.enrolled, activeDays: {'2027-01-01', '2027-02-01'}));
      final client = FakeRewardClient((occasion) => const FestivalMissed());
      final subject = festivals(client: client, memory: memory);
      await subject.recordActive();
      await subject.recordActive();
      expect(memory.record.activeDays, {'2027-02-01', '2027-02-06'});
      await subject.draw(spring);
      expect(client.requests.single.activeDays, 2);
    });

    // 回归：draw 的 whenComplete 曾写成箭头体，remove 返回的正是这个 Future，Future 等自己、永远完成不了，动画后的揭晓被超时吃掉。
    test('抽签会完成并给出结果；同一时刻只发一次；抽中的记成没揭晓的奖品，揭晓后记下', () async {
      final client = FakeRewardClient((occasion) => FestivalWon(prize(occasion)))..gate = Completer<void>();
      final subject = festivals(client: client);
      final first = subject.draw(spring), second = subject.draw(spring);
      client.gate!.complete();
      final results = await Future.wait([first, second]).timeout(const Duration(seconds: 2));
      expect(results.every((result) => result is FestivalWon), isTrue);
      expect(client.requests, hasLength(1));
      expect(subject.unrevealed?.occasion, 'spring-2027');
      await subject.markRevealed(subject.unrevealed!);
      expect(subject.unrevealed, isNull);
      expect(subject.prizes, hasLength(1));
      expect(await subject.draw(spring), isNull, reason: '结果已定，不再抽');
    });

    test('连不上不记结果，回到前台补抽一次（只补播过、有抽奖、今天还在过的）；没配中转或没有抽奖不抽', () async {
      final memory = FileFestivalMemory.memory(enrolled);
      final client = FakeRewardClient((occasion) => const FestivalMissed())..failure = const FestivalException('连不上服务器');
      final subject = festivals(client: client, memory: memory);
      expect(await subject.draw(spring), isNull);
      expect(memory.record.drawn, isEmpty);
      client.failure = null;
      await subject.refresh();
      expect(client.requests, hasLength(1), reason: '还没播过的不补抽');
      await subject.markPlayed(spring);
      await subject.refresh();
      expect(client.requests, hasLength(2));
      expect(memory.record.drawn, ['spring-2027']);
      expect(await festivals().draw(spring), isNull);
      expect(await subject.draw(lantern), isNull);
    });

    test('按需登记抽奖身份：节日前 7 天以前不碰；进了窗口登记一次，没登记成就下次打开再试；节日过后撤下，没撤成下次再撤', () async {
      final memory = FileFestivalMemory.memory(), pass = FakePass();
      var now = campusNoon(1, 29);
      final subject = Festivals(occasions: const [spring, lantern], memory: memory, pass: pass, client: FakeRewardClient((occasion) => const FestivalMissed()), clock: () => now);
      await subject.prepare();
      expect(pass.calls, isEmpty, reason: '离节日还有 8 天：不生成密钥、不联网');
      expect(memory.record.pass, FestivalPassState.none);
      now = campusNoon(1, 30);
      pass.failure = const FestivalException('请求过于频繁');
      await subject.prepare();
      expect(pass.calls, ['enroll']);
      expect(memory.record.pass, FestivalPassState.created, reason: '被限流：记下生成过，下次再登记');
      pass.failure = null;
      await subject.prepare();
      await subject.prepare();
      expect(pass.calls, ['enroll', 'enroll'], reason: '登记成功后不再登记');
      expect(memory.record.pass, FestivalPassState.enrolled);
      now = campusNoon(2, 9);
      pass.failure = const FestivalException('连不上服务器');
      await subject.prepare();
      expect(memory.record.pass, FestivalPassState.enrolled, reason: '没撤成：留着下次再撤');
      pass.failure = null;
      await subject.prepare();
      await subject.prepare();
      expect(pass.calls, ['enroll', 'enroll', 'retire', 'retire']);
      expect(memory.record.pass, FestivalPassState.none);
      // 只有没抽奖的节日：怎么都不碰。
      final quiet = FakePass();
      await Festivals(occasions: const [lantern], memory: FileFestivalMemory.memory(), pass: quiet, clock: () => campusNoon(2, 20)).prepare();
      expect(quiet.calls, isEmpty);
    });

    test('登记没成也撤：生成过密钥、节日过了还没登记成功的，同样请中转删、删本机密钥', () async {
      final memory = FileFestivalMemory.memory(const FestivalRecord(pass: FestivalPassState.created)), pass = FakePass();
      await Festivals(occasions: const [spring], memory: memory, pass: pass, clock: () => campusNoon(2, 9)).prepare();
      expect(pass.calls, ['retire']);
      expect(memory.record.pass, FestivalPassState.none);
    });

    test('抽签前没登记成功不抽、等下次；登记在路上时先等它；中转不认这台设备时记回没登记，下次打开重新登记后补抽', () async {
      final memory = FileFestivalMemory.memory(), pass = FakePass()..failure = const FestivalException('连不上服务器');
      final client = FakeRewardClient((occasion) => const FestivalMissed());
      final subject = festivals(client: client, pass: pass, memory: memory);
      await subject.markPlayed(spring);
      await subject.refresh();
      expect(client.requests, isEmpty, reason: '没登记成功的不抽');
      expect(memory.record.drawn, isEmpty);
      pass
        ..failure = null
        ..gate = Completer<void>();
      final preparing = subject.prepare();
      final drawing = subject.draw(spring);
      pass.gate!.complete();
      await preparing;
      expect(await drawing, isA<FestivalMissed>(), reason: '等登记完再抽');
      expect(client.requests, hasLength(1));
      // 下一次节日：中转已经不认这台设备。
      final next = FakeRewardClient((occasion) => const FestivalMissed())..failure = const FestivalNotEnrolled();
      final again = Festivals(occasions: const [spring], memory: FileFestivalMemory.memory(enrolled), pass: pass, client: next, clock: () => noon);
      await again.markPlayed(spring);
      expect(await again.draw(spring), isNull);
      next.failure = null;
      pass.calls.clear();
      await again.refresh();
      expect(pass.calls, ['enroll'], reason: '记回没登记，回到前台重新登记');
      expect(next.requests, hasLength(2));
    });
  });

  group('抽奖身份与抽签客户端（经假中转）', () {
    test('登记到中转、抽签用抽奖身份签名且只发活跃天数；与私信身份分开存；撤下时中转删设备、本机删密钥', () async {
      final relay = FakeRelay(), transport = _RewardRelay(relay), vault = MemoryIdentityVault(), social = MemoryIdentityVault();
      social.identity = await SocialIdentity.generate();
      final pass = RelayFestivalPass(vault: vault, transport: transport);
      await pass.enroll();
      final deviceId = vault.identity!.deviceId;
      expect(relay.devices.keys, [deviceId], reason: '中转按自签名登记了这台抽奖设备');
      expect(deviceId, isNot(social.identity!.deviceId));
      await pass.enroll();
      expect(vault.identity!.deviceId, deviceId, reason: '再登记沿用同一把密钥');
      transport.result = {'result': 'won', 'prize': {'kind': 'password', 'content': '口令', 'note': ''}};
      final result = await RelayRewardClient(pass).draw('spring-2027', occasion: 'spring-2027', activeDays: 7);
      expect((result as FestivalWon).prize.content, '口令');
      expect(transport.draws.single.device, deviceId);
      expect(transport.draws.single.path, '/v1/rewards/spring-2027/draw');
      expect(transport.draws.single.body, {'activeDays': 7});
      transport.result = {'result': 'won'};
      await expectLater(RelayRewardClient(pass).draw('spring-2027', occasion: 'spring-2027', activeDays: 7), throwsA(isA<FestivalException>().having((error) => error.message, 'message', contains('格式'))));
      relay.failNext = const RelayException(RelayCode.network);
      await expectLater(RelayRewardClient(pass).draw('spring-2027', occasion: 'spring-2027', activeDays: 7), throwsA(isA<FestivalException>().having((error) => error.message, 'message', contains('连不上'))));
      await pass.retire();
      expect(relay.devices, isEmpty);
      expect(vault.identity, isNull);
      expect(social.identity, isNotNull, reason: '私信身份不受影响');
      await expectLater(pass.post('/v1/rewards/spring-2027/draw', {'activeDays': 1}), throwsA(isA<FestivalNotEnrolled>()), reason: '本机没有密钥');
    });

    test('中转不认这台设备：抽签算没登记；撤下时照样删本机密钥；连不上时本机密钥留着下次再撤', () async {
      final relay = FakeRelay(), vault = MemoryIdentityVault();
      final pass = RelayFestivalPass(vault: vault, transport: _RewardRelay(relay));
      vault.identity = await SocialIdentity.generate();
      await expectLater(RelayRewardClient(pass).draw('spring-2027', occasion: 'spring-2027', activeDays: 1), throwsA(isA<FestivalNotEnrolled>()));
      await pass.enroll();
      relay.failNext = const RelayException(RelayCode.timeout);
      await expectLater(pass.retire(), throwsA(isA<FestivalException>()));
      expect(vault.identity, isNotNull);
      relay.devices.clear();
      await pass.retire();
      expect(vault.identity, isNull);
    });

    test('从头走一遍：节日前一周打开时登记，节日当天抽签带抽奖设备的签名，节日过后撤下', () async {
      final relay = FakeRelay(), transport = _RewardRelay(relay), vault = MemoryIdentityVault();
      final pass = RelayFestivalPass(vault: vault, transport: transport);
      var now = campusNoon(1, 30);
      final subject = Festivals(occasions: const [spring], memory: FileFestivalMemory.memory(), pass: pass, client: RelayRewardClient(pass), clock: () => now);
      await subject.refresh();
      expect(relay.devices, hasLength(1));
      now = noon;
      await subject.markPlayed(spring);
      expect(await subject.draw(spring), isA<FestivalMissed>());
      expect(transport.draws.single.device, relay.devices.keys.single);
      now = campusNoon(2, 9);
      await subject.refresh();
      expect(relay.devices, isEmpty);
      expect(vault.identity, isNull);
    });
  });

  group('打扰时机的先后', () {
    test('节日动画先于没揭晓的奖品，奖品先于新信；播过就轮到下一件', () async {
      final notes = DeveloperNotes(feed: _Notes(), memory: FileDeveloperNoteMemory.memory(), clock: () => noon);
      await notes.refresh();
      final memory = FileFestivalMemory.memory(FestivalRecord(prizes: [prize('spring-2027')]));
      final festivals = Festivals(occasions: const [spring], memory: memory, clock: () => noon);
      final moments = AppMoments(notes: notes, festivals: festivals, timetable: () async => const CampusTimetable(<CourseOccurrence>[]), clock: () => noon);
      addTearDown(moments.dispose);
      expect(await moments.next(), isA<CelebrationMoment>());
      await festivals.markPlayed(spring);
      expect(await moments.next(), isA<RewardMoment>());
      await festivals.markRevealed(festivals.unrevealed!);
      expect(await moments.next(), isA<NoteLetterMoment>());
    });
  });

  group('界面', () {
    // 减少动画要套在整个应用外面：浮层路由不在首页的子树里。
    Widget host(void Function(BuildContext context) open, {bool reduced = false}) => MaterialApp(
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reduced), child: child!),
      home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(onPressed: () => open(context), child: const Text('打开'))))),
    );

    testWidgets('节日动画放完自己关；点一下立即关；减少动画时显示问候、一会儿自己关；导航栏透明、不涂成黑条', (tester) async {
      var built = 0.0;
      final scene = FestivalScene(occasion: spring, length: const Duration(seconds: 2), builder: (context, progress) => AnimatedBuilder(animation: progress, builder: (context, _) {
        built = progress.value;
        return const Text('场景');
      }));
      await tester.pumpWidget(host((context) => showFestivalCelebration(context, scene)));
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('场景'), findsOneWidget);
      expect(SystemChrome.latestStyle?.systemNavigationBarColor, Colors.transparent);
      expect(SystemChrome.latestStyle?.systemNavigationBarIconBrightness, Brightness.light);
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
      expect(built, 1);
      expect(find.text('场景'), findsNothing);
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('场景'), findsNothing);
      await tester.pumpWidget(host((context) => showFestivalCelebration(context, scene), reduced: true));
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('新春快乐'), findsOneWidget);
      await tester.pump(festivalStillLength);
      await tester.pumpAndSettle();
      expect(find.text('新春快乐'), findsNothing);
    });

    testWidgets('拆红包：点开星核后卡片出来；口令复制并打开支付宝；「收下了」关闭；导航栏透明、不涂成黑条', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final opened = <Uri>[];
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(host((context) => showFestivalReward(context, prize: prize('spring-2027'), title: '新春快乐', openUri: (uri) async {
        opened.add(uri);
        return true;
      })));
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('复制口令，去支付宝'), findsNothing, reason: '还没拆');
      expect(find.bySemanticsLabel('拆开红包'), findsOneWidget);
      expect(SystemChrome.latestStyle?.systemNavigationBarColor, Colors.transparent);
      expect(SystemChrome.latestStyle?.systemNavigationBarIconBrightness, Brightness.light);
      await tester.tap(find.bySemanticsLabel('拆开红包'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2200));
      expect(find.text('88662027'), findsOneWidget);
      await tester.tap(find.text('复制口令，去支付宝'));
      await tester.pump();
      expect(copied, '88662027');
      expect(opened.single, alipayHome);
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.text('收下了'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
      expect(find.text('88662027'), findsNothing);
    });

    testWidgets('二维码：先用支付宝扫一扫的链接直接识别，不行而内容是网页链接时交给系统打开；减少动画时不拆红包，直接是卡片', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final opened = <Uri>[];
      await tester.pumpWidget(host((context) => showFestivalReward(context, prize: prize('spring-2027', kind: FestivalPrizeKind.qrCode, content: 'https://qr.alipay.com/abc'), title: '新春快乐', openUri: (uri) async {
        opened.add(uri);
        return uri.isScheme('https');
      }), reduced: true));
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.bySemanticsLabel('拆开红包'), findsNothing);
      await tester.tap(find.text('在支付宝里打开'));
      await tester.pump();
      expect(opened, [alipayQrUri('https://qr.alipay.com/abc'), Uri.parse('https://qr.alipay.com/abc')]);
      expect(opened.first.queryParameters, {'saId': '10000007', 'qrcode': 'https://qr.alipay.com/abc'});
    });
  });

  test('今天的校园日按校园时区算（节日日界的依据）', () {
    expect(formatCampusDate(campusInstant(DateTime.utc(2027, 2, 5, 16))), '2027-02-06');
  });
}

class _Notes implements DeveloperNoteFeed {
  @override
  Future<List<DeveloperNote>> fetch() async => [DeveloperNote(id: 'n', title: '近况', publishedAt: DateTime.utc(2027, 2, 6), body: '正文')];
}
