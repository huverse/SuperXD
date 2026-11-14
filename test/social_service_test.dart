import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_spaces.dart';
import 'package:superxd/social/social_store.dart';

import 'fake_relay.dart';
import 'share_card_test.dart' show sampleSchedule;

late Directory temporary;
var _phones = 0;
final _phoneOf = Expando<Phone>();

// 一台测试手机：自己的数据库目录、私信身份存放与应用账号密钥。start 起一个私信服务并切到当前应用账号；重启 = stop 关库后再 start。
class Phone {
  Phone(this.relay) : directory = Directory(path.join(temporary.path, 'phone_${_phones++}'))..createSync();
  final FakeRelay? relay;
  final Directory directory;
  final vault = MemoryIdentityVault();
  final keys = MemoryAppAccountVault();
  AppAccountRef? account;
  SocialSpaces? _spaces;
  var gone = 0;

  // 登录应用账号（给账号号就登到已有的账号：同一个人的另一台手机）。
  Future<AppAccountRef> signIn({String? accountId}) async => account = await relay!.signIn(keys, accountId: accountId);

  Future<SocialService> start({bool polling = false, Random? random}) async {
    final spaces = _spaces = SocialSpaces(vault: vault, directory: directory.path);
    final service = SocialService(spaces: spaces, accountKeys: keys, transport: relay?.transport(), accountGone: () => gone++, polling: polling, random: random);
    _phoneOf[service] = this;
    await service.switchAccount(account);
    return service;
  }

  Future<SocialStore> store([AppAccountRef? of]) async => (await _spaces!.of((of ?? account)!.accountId)).store;
  Future<void> stop() async => (await store()).close();
  Future<SocialIdentity?> identity([AppAccountRef? of]) async => vault.read((await _spaces!.of((of ?? account)!.accountId)).identityKey);
}

Phone phoneOf(SocialService service) => _phoneOf[service]!;
Future<SocialStore> storeOf(SocialService service) => phoneOf(service).store();

// 一台登录了应用账号的手机上的私信服务（没配中转时不登录）。
Future<SocialService> device(FakeRelay? relay, {bool polling = false, Random? random}) async {
  final phone = Phone(relay);
  if (relay != null) await phone.signIn();
  return phone.start(polling: polling, random: random);
}

Future<(SocialService, SocialService)> friendsPair(FakeRelay relay) async {
  final alice = await device(relay), bob = await device(relay);
  await alice.enable('小红');
  await bob.enable('小明');
  await bob.redeem(InviteCode.decode((await alice.createInvite()).encode())!);
  await alice.refresh();
  return (alice, bob);
}

// 等到条件成立（真实时间，最多 timeout）。
Future<void> eventually(bool Function() condition, {Duration timeout = const Duration(seconds: 6)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('超时未满足条件');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  // 长轮询用到生命周期监听，需要绑定。
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => temporary = Directory.systemTemp.createTempSync('social_test'));
  tearDown(() => temporary.deleteSync(recursive: true));

  test('未配置中转服务时不可用，不联网', () async {
    final service = await device(null);
    expect(service.status, SocialStatus.unavailable);
  });

  test('开启：生成身份、挂到当前应用账号（顺带登记设备）、保存昵称；昵称不合规拒绝', () async {
    final relay = FakeRelay();
    final service = await device(relay);
    expect(service.status, SocialStatus.disabled);
    expect(() => service.enable(' 空格'), throwsArgumentError);
    await service.enable('小红');
    expect(service.status, SocialStatus.ready);
    expect(relay.devices.containsKey(service.deviceId), isTrue);
    expect(relay.accountSocial[phoneOf(service).account!.accountId], service.deviceId);
    expect((await (await storeOf(service)).profile())!.bound, isTrue);
  });

  test('挂账号失败时保留身份与昵称，下次打开补挂；连不上时是暂时不可用，点重试再挂', () async {
    final relay = FakeRelay();
    final phone = Phone(relay);
    await phone.signIn();
    final first = await phone.start();
    relay.failNext = const RelayException(RelayCode.network);
    await expectLater(first.enable('小红'), throwsA(isA<SocialException>().having((error) => error.code, 'code', RelayCode.network)));
    expect(first.status, SocialStatus.disabled);
    await phone.stop();
    relay.failNext = const RelayException(RelayCode.network);
    final second = await phone.start();
    expect(second.status, SocialStatus.failed);
    await second.reopen();
    expect(second.status, SocialStatus.ready);
    expect(relay.accountSocial[phone.account!.accountId], (await phone.identity())!.deviceId);
  });

  test('扫码即互为好友：双方都看到对方昵称与“已成为好友”，信箱取完即删', () async {
    final relay = FakeRelay();
    final (alice, bob) = await friendsPair(relay);
    expect(bob.friends.single.nickname, '小红');
    expect(alice.friends.single.nickname, '小明');
    expect(alice.friends.single.deviceId, bob.deviceId);
    expect((await alice.conversation(bob.deviceId!)).single.system, 'friend_added');
    expect((await bob.conversation(alice.deviceId!)).single.system, 'friend_added');
    expect(relay.mailbox, isEmpty);
  });

  test('发送课表：发送方原地显示已发送，接收方收到、未读加一、预览更新，读后清零', () async {
    final relay = FakeRelay();
    final (alice, bob) = await friendsPair(relay);
    final sent = await bob.send(alice.deviceId!, sampleSchedule());
    expect(sent.state, MessageState.sent);
    await alice.refresh();
    final received = (await alice.conversation(bob.deviceId!)).first;
    expect(received.card, isA<ScheduleShare>());
    expect((received.card! as ScheduleShare).courses, hasLength(3));
    expect(alice.unread, 1);
    expect(alice.friends.single.lastPreview, '[课表] 2026-2027学年第一学期');
    await alice.markRead(bob.deviceId!);
    expect(alice.unread, 0);
  });

  test('中转重复投递同一条消息只入库一次', () async {
    final relay = FakeRelay();
    final (alice, bob) = await friendsPair(relay);
    await bob.send(alice.deviceId!, const AppearanceShare(paletteId: 'mist', fontId: 'maple', scale: 1, themeMode: 'system', glassMode: 'auto', wallpaperBlur: 27, wallpaperFade: 0));
    final copy = relay.mailbox.single;
    relay.mailbox.add((id: copy.id + 100, recipient: copy.recipient, sender: copy.sender, clientId: 'dup', envelope: copy.envelope, createTime: copy.createTime));
    await alice.refresh();
    expect((await alice.conversation(bob.deviceId!)).where((message) => message.card != null), hasLength(1));
    expect(alice.unread, 1);
  });

  test('服务器伪造的问候（凭证不是本机邀请私钥签的）被丢弃，不加好友', () async {
    final relay = FakeRelay();
    final alice = await device(relay), mallory = await device(relay);
    await alice.enable('小红');
    await mallory.enable('冒充者');
    final real = await alice.createInvite();
    // 中转服务知道邀请号与邀请公钥，但没有私钥：用自己生成的邀请私钥签凭证，再塞进 alice 的信箱。
    final fakeSeed = secureRandomBytes(32);
    final forged = InviteCode(inviteId: real.inviteId, inviteSeed: fakeSeed, owner: real.owner, nickname: real.nickname, expiresAt: real.expiresAt);
    relay.invites[real.inviteId] = (owner: alice.deviceId!, publicKey: await ed25519PublicOf(fakeSeed), expiresAt: real.expiresAt);
    await mallory.redeem(forged);
    await alice.refresh();
    expect(alice.friends, isEmpty);
    expect(relay.mailbox, isEmpty);
  });

  test('非好友发来的卡片丢弃并确认删除，不反复拉取', () async {
    final relay = FakeRelay();
    final (alice, bob) = await friendsPair(relay);
    await (await storeOf(alice)).deleteFriend(bob.deviceId!);
    await bob.send(alice.deviceId!, sampleSchedule());
    await alice.refresh();
    expect(await alice.conversation(bob.deviceId!), isEmpty);
    expect(relay.mailbox, isEmpty);
  });

  test('断网发送失败记错误码；重发沿用同一消息号，服务端不重复', () async {
    final relay = FakeRelay();
    final (alice, bob) = await friendsPair(relay);
    relay.failNext = const RelayException(RelayCode.timeout);
    final failed = await bob.send(alice.deviceId!, sampleSchedule());
    expect(failed.state, MessageState.failed);
    expect(failed.error, RelayCode.timeout);
    final retried = await bob.retry(failed.id);
    expect(retried.state, MessageState.sent);
    expect(retried.id, failed.id);
    await bob.retry(failed.id);
    expect(relay.mailbox, hasLength(1));
  });

  test('对方删除好友后：发送被拒并标记已解除；核对好友列表同样标记', () async {
    final relay = FakeRelay();
    final (alice, bob) = await friendsPair(relay);
    await alice.removeFriend(bob.deviceId!);
    expect(alice.friends, isEmpty);
    final rejected = await bob.send(alice.deviceId!, sampleSchedule());
    expect(rejected.error, RelayCode.notFriend);
    expect(bob.friends.single.removed, isTrue);
    final again = await bob.retry(rejected.id);
    expect(again.error, SocialCode.friendRemoved);

    final (carol, dave) = await friendsPair(relay);
    await carol.removeFriend(dave.deviceId!);
    await dave.refresh(reconcile: true);
    expect(dave.friends.single.removed, isTrue);
  });

  test('重新扫码加回已解除的好友，会话保留并恢复可发送', () async {
    final relay = FakeRelay();
    final (alice, bob) = await friendsPair(relay);
    await bob.send(alice.deviceId!, sampleSchedule());
    await alice.removeFriend(bob.deviceId!);
    await bob.refresh(reconcile: true);
    await bob.redeem(InviteCode.decode((await alice.createInvite()).encode())!);
    expect(bob.friends.single.removed, isFalse);
    expect((await bob.conversation(alice.deviceId!)).where((message) => message.system == 'friend_added'), hasLength(2));
    expect((await bob.send(alice.deviceId!, sampleSchedule())).state, MessageState.sent);
  });

  test('设备时钟偏差：收到服务器时间后校正并只重发一次', () async {
    final relay = FakeRelay()..serverOffset = 10 * 60 * 1000;
    final service = await device(relay);
    await service.enable('小红');
    expect(service.status, SocialStatus.ready);
    expect(relay.calls.where((call) => call == 'POST /v1/account/social'), hasLength(2));
  });

  test('扫码前置检查：本机判定过期、扫自己', () async {
    final relay = FakeRelay();
    final alice = await device(relay);
    await alice.enable('小红');
    final own = await alice.createInvite();
    await expectLater(alice.redeem(own), throwsA(isA<SocialException>().having((error) => error.code, 'code', RelayCode.inviteSelf)));
    final bob = await device(relay);
    await bob.enable('小明');
    final expired = InviteCode(inviteId: own.inviteId, inviteSeed: own.inviteSeed, owner: own.owner, nickname: own.nickname, expiresAt: DateTime.now().millisecondsSinceEpoch - 1);
    await expectLater(bob.redeem(expired), throwsA(isA<SocialException>().having((error) => error.code, 'code', SocialCode.inviteExpired)));
    // 新建邀请作废旧邀请：旧二维码在服务端失效。
    await alice.createInvite();
    await expectLater(bob.redeem(own), throwsA(isA<SocialException>().having((error) => error.code, 'code', RelayCode.inviteNotFound)));
  });

  test('每个好友只保留最近 200 条', () async {
    final relay = FakeRelay();
    final (alice, bob) = await friendsPair(relay);
    for (var index = 0; index < 205; index++) {
      await (await storeOf(bob)).addCard(id: 'id-${index.toString().padLeft(4, '0')}', friendId: alice.deviceId!, outgoing: true, state: MessageState.sent, card: sampleSchedule(), now: DateTime.now().toUtc().add(Duration(seconds: index + 1)).toIso8601String());
    }
    final kept = await bob.conversation(alice.deviceId!);
    expect(kept, hasLength(conversationLimit));
    expect(kept.first.id, 'id-0204');
    expect(kept.any((message) => message.system == 'friend_added'), isFalse);
  });

  test('关闭私信：服务端删除设备、关系与挂账号的登记，本机清空库与身份', () async {
    final relay = FakeRelay();
    final (alice, bob) = await friendsPair(relay);
    final carol = await device(relay);
    await carol.enable('小青');
    final carolId = carol.deviceId;
    await carol.disable();
    expect(carol.status, SocialStatus.disabled);
    expect(carol.deviceId, isNull);
    expect(relay.devices.containsKey(carolId), isFalse);
    expect(relay.accountSocial, isNot(contains(phoneOf(carol).account!.accountId)));
    expect(await phoneOf(carol).identity(), isNull);
    expect(await (await storeOf(carol)).profile(), isNull);
    final aliceId = alice.deviceId!;
    await alice.disable();
    expect(relay.friends(bob.deviceId!, aliceId), isFalse);
  });

  // 中转丢了这台设备（从旧备份恢复、400 天不活跃被清）：设备记录连同好友关系与挂账号的登记一起没了。
  void forgetDevice(FakeRelay relay, String deviceId) {
    relay.devices.remove(deviceId);
    relay.friendships.removeWhere((pair) => pair.split('|').contains(deviceId));
    relay.accountSocial.removeWhere((_, social) => social == deviceId);
  }

  test('中转丢了本设备：下一次请求遇 UNAUTHORIZED 自动重新挂账号一次并重放，之后照常可用', () async {
    final relay = FakeRelay();
    final (alice, bob) = await friendsPair(relay);
    forgetDevice(relay, bob.deviceId!);
    relay.calls.clear();
    final invite = await bob.createInvite();
    expect(relay.devices.containsKey(bob.deviceId), isTrue);
    expect(relay.calls, ['POST /v1/invites', 'POST /v1/account/social', 'POST /v1/invites']);
    // 服务端的好友关系随设备没了：发送照常回 NOT_FRIEND 并标记已解除，重新扫码即可恢复。
    final rejected = await bob.send(alice.deviceId!, sampleSchedule());
    expect(rejected.error, RelayCode.notFriend);
    await alice.redeem(invite);
    await bob.refresh();
    expect(bob.friends.single.removed, isFalse);
    expect((await bob.send(alice.deviceId!, sampleSchedule())).state, MessageState.sent);
  });

  test('中转丢了本设备：重新挂账号失败报它的错误码，只重放一次、不再重试', () async {
    final relay = FakeRelay();
    final service = await device(relay);
    await service.enable('小红');
    forgetDevice(relay, service.deviceId!);
    relay.calls.clear();
    relay.failOn = ('POST /v1/account/social', const RelayException(RelayCode.rateLimited));
    await expectLater(service.createInvite(), throwsA(isA<SocialException>().having((error) => error.code, 'code', RelayCode.rateLimited)));
    expect(relay.calls, ['POST /v1/invites', 'POST /v1/account/social']);
    // 下一次操作再遇到时照样只挂一次。
    await service.createInvite();
    expect(relay.calls.skip(2), ['POST /v1/invites', 'POST /v1/account/social', 'POST /v1/invites']);
  });

  test('中转丢了本设备：几个请求同时遇到 UNAUTHORIZED 只挂一次', () async {
    final relay = FakeRelay();
    final service = await device(relay);
    await service.enable('小红');
    forgetDevice(relay, service.deviceId!);
    relay.calls.clear();
    await Future.wait([service.createInvite(), service.refresh(reconcile: true)]);
    expect(relay.calls.where((call) => call == 'POST /v1/account/social'), hasLength(1));
    expect(service.refreshError, isNull);
  });

  test('中转丢了本设备：前台长轮询重新挂账号后继续收消息', () async {
    final relay = FakeRelay();
    final bob = await device(relay);
    await bob.enable('小明');
    final phone = Phone(relay);
    await phone.signIn();
    final first = await phone.start();
    await first.enable('小红');
    await phone.stop();
    forgetDevice(relay, first.deviceId!);
    relay.calls.clear();
    // 重新启动：本机记着已挂上、启动时不再挂，由长轮询遇到 UNAUTHORIZED 补上。
    final restarted = await phone.start(polling: true);
    await eventually(() => relay.devices.containsKey(restarted.deviceId));
    expect(relay.calls.take(3), ['GET /v1/messages', 'POST /v1/account/social', 'GET /v1/messages']);
    await bob.redeem(InviteCode.decode((await restarted.createInvite()).encode())!);
    await bob.send(restarted.deviceId!, sampleSchedule());
    await eventually(() => restarted.unread == 1);
    restarted.dispose();
    relay.releaseWaiters();
  });

  test('关闭私信：中转已经不认这台设备时照样清空本机', () async {
    final relay = FakeRelay();
    final service = await device(relay);
    await service.enable('小红');
    forgetDevice(relay, service.deviceId!);
    relay.calls.clear();
    await service.disable();
    expect(relay.calls, ['DELETE /v1/devices']);
    expect(service.status, SocialStatus.disabled);
    expect(await phoneOf(service).identity(), isNull);
    expect(await (await storeOf(service)).profile(), isNull);
  });

  test('身份丢失（安全存储被清）时回到未开启，清掉无法解密的旧数据', () async {
    final relay = FakeRelay();
    final phone = Phone(relay);
    await phone.signIn();
    final first = await phone.start();
    await first.enable('小红');
    await phone.stop();
    phone.vault.identities.clear();
    final second = await phone.start();
    expect(second.status, SocialStatus.disabled);
    expect(await (await phone.store()).profile(), isNull);
  });

  test('启动时把中断的“发送中”改为失败，由用户重发', () async {
    final relay = FakeRelay();
    final phone = Phone(relay);
    await phone.signIn();
    final first = await phone.start();
    await first.enable('小红');
    await (await phone.store()).addCard(id: 'pending', friendId: 'x', outgoing: true, state: MessageState.sending, card: sampleSchedule(), now: DateTime.now().toUtc().toIso8601String());
    await phone.stop();
    await phone.start();
    expect((await (await phone.store()).message('pending'))!.state, MessageState.failed);
  });

  test('前台长轮询：对方发送后不用手动刷新就收到，挂起的请求立即返回', () async {
    final relay = FakeRelay();
    final alice = await device(relay, polling: true), bob = await device(relay);
    await alice.enable('小红');
    await bob.enable('小明');
    await bob.redeem(InviteCode.decode((await alice.createInvite()).encode())!);
    await eventually(() => alice.friends.length == 1);
    final started = DateTime.now();
    await bob.send(alice.deviceId!, sampleSchedule());
    await eventually(() => alice.unread == 1);
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 2)));
    // 挂起中的拉取都带 wait，不是立即返回的短轮询。
    expect(relay.calls.where((call) => call == 'GET /v1/messages'), isNotEmpty);
    alice.dispose();
    relay.releaseWaiters();
  });

  test('前台长轮询：网络失败退避后自动恢复', () async {
    final relay = FakeRelay();
    final bob = await device(relay);
    await bob.enable('小明');
    final phone = Phone(relay);
    await phone.signIn();
    final first = await phone.start();
    await first.enable('小青');
    await bob.redeem(InviteCode.decode((await first.createInvite()).encode())!);
    await first.refresh();
    await phone.stop();
    // 重开为带长轮询的实例，第一次拉取就断网：退避 2 秒后应恢复并收到。
    relay.failNext = const RelayException(RelayCode.network);
    final resumed = await phone.start(polling: true);
    await bob.send(resumed.deviceId!, sampleSchedule());
    await eventually(() => resumed.unread == 1, timeout: const Duration(seconds: 8));
    resumed.dispose();
    relay.releaseWaiters();
  });

  // [人工决策] 见 social_service.dart 的 liveRetryDelay：退避每档不变，实际等待在一半到整档之间随机。
  test('长轮询退避加随机抖动：落在这一档的一半到整档之间，随机源可注入；失败后按抖动后的时长重来', () async {
    expect(SocialService.liveRetryDelay(const Duration(seconds: 2), _FixedRandom(0)), const Duration(seconds: 1));
    expect(SocialService.liveRetryDelay(const Duration(seconds: 60), _FixedRandom(0.5)), const Duration(seconds: 45));
    final random = Random(7);
    final delays = {for (var index = 0; index < 50; index++) SocialService.liveRetryDelay(const Duration(seconds: 8), random)};
    expect(delays.every((delay) => delay >= const Duration(seconds: 4) && delay <= const Duration(seconds: 8)), isTrue);
    expect(delays.length, greaterThan(10), reason: '不是同一个值');

    final logs = <String>[];
    final original = campusLog;
    campusLog = logs.add;
    addTearDown(() => campusLog = original);
    final relay = FakeRelay();
    final phone = Phone(relay);
    await phone.signIn();
    final first = await phone.start();
    await first.enable('小青');
    await phone.stop();
    relay.failNext = const RelayException(RelayCode.network);
    final random0 = _FixedRandom(0);
    final resumed = await phone.start(polling: true, random: random0);
    await eventually(() => logs.any((log) => log.startsWith('[Social] action=live state=retry')));
    expect(logs.firstWhere((log) => log.startsWith('[Social] action=live state=retry')), contains('retryIn=1s'), reason: '第一档 2 秒、抖动取到下限 1 秒');
    expect(random0.calls, 1);
    resumed.dispose();
    relay.releaseWaiters();
  });

  test('HTTP 传输失败记日志：错误码、方法与路径、完整堆栈，不写服务器地址与查询参数', () async {
    final logs = <String>[];
    final original = campusLog;
    campusLog = logs.add;
    addTearDown(() => campusLog = original);
    Future<String> failure(MockClient client, {Duration timeout = const Duration(seconds: 15)}) async {
      logs.clear();
      final transport = HttpRelayTransport('http://relay.invalid:8080', client: client, timeout: timeout);
      await expectLater(transport.send('GET', '/v1/messages?after=secret-cursor&limit=50', const {}, null), throwsA(isA<RelayException>()));
      expect(logs, hasLength(1));
      final log = logs.single;
      expect(log, startsWith('[RelayTransport] action=request route=GET /v1/messages '));
      expect(log, contains('relay_client.dart'), reason: '应附完整堆栈');
      expect(log, isNot(contains('relay.invalid')));
      expect(log, isNot(contains('secret-cursor')));
      return log;
    }

    expect(await failure(MockClient((_) async => throw http.ClientException('connection refused'))), contains('code=NETWORK errorType=ClientException'));
    expect(
      await failure(MockClient((_) => Completer<http.Response>().future), timeout: const Duration(milliseconds: 50)),
      contains('code=TIMEOUT errorType=TimeoutException'),
    );
    expect(await failure(MockClient((_) async => http.Response('<html>', 502))), contains('code=BAD_RESPONSE status=502 errorType=FormatException'));
  });

  // [人工决策] 见 social_service.dart 的 liveFailureLimit：长轮询的断网与超时连续失败才算错误。
  test('长轮询断网、超时：传输层不记错误，收取循环连续失败到上限那次才记一条错误；发成功不带 errorType', () async {
    final logs = <String>[];
    final original = campusLog;
    campusLog = logs.add;
    addTearDown(() => campusLog = original);
    final transport = HttpRelayTransport('http://relay.invalid:8080', client: MockClient((_) async => throw http.ClientException('connection reset')));
    await expectLater(transport.send('GET', '/v1/messages?wait=25', const {}, null, background: true), throwsA(isA<RelayException>()));
    expect(logs, isEmpty, reason: '后台长轮询的断网交给收取循环决定');

    String line(Object error, int failures) => SocialService.liveFailureLog(error, StackTrace.current, failures: failures, retryIn: const Duration(seconds: 2));
    for (var failures = 1; failures <= SocialService.liveFailureLimit + 2; failures++) {
      for (final code in [RelayCode.network, RelayCode.timeout]) {
        expect(line(RelayException(code), failures).contains('errorType='), failures == SocialService.liveFailureLimit, reason: '$code 第 $failures 次');
      }
    }
    expect(line(const RelayException(RelayCode.notFriend), 1), contains('errorType=${RelayCode.notFriend}'), reason: '中转回的其他错误码照常算错误');
    expect(line(StateError('坏了'), 1), allOf(contains('errorType=StateError'), contains('social_service_test.dart')), reason: '其他异常带堆栈');

    final relay = FakeRelay();
    final alice = await device(relay), bob = await device(relay);
    await alice.enable('小明');
    await bob.enable('小青');
    await alice.redeem(InviteCode.decode((await bob.createInvite()).encode())!);
    await bob.refresh();
    logs.clear();
    await alice.send(bob.deviceId!, sampleSchedule());
    final sent = logs.singleWhere((log) => log.startsWith('[Social] action=send'));
    expect(sent, contains('state=sent'));
    expect(sent, isNot(contains('errorType=')), reason: '带 errorType= 就会被本机日志当成错误');
  });

  // 人工决策见 social_service.dart 文件头（11-14 两条）：私信跟着应用账号。
  group('私信跟着应用账号', () {
    test('没登录应用账号时停用、不联网；登录后切过去就能开启', () async {
      final relay = FakeRelay();
      final phone = Phone(relay);
      final service = await phone.start();
      expect(service.status, SocialStatus.signedOut);
      expect(relay.calls, isEmpty);
      await service.switchAccount(await phone.signIn());
      expect(service.status, SocialStatus.disabled);
      await service.enable('小红');
      expect(service.status, SocialStatus.ready);
    });

    test('每个应用账号一份：同一台手机上换账号就换一份身份、好友与会话，换回来照旧；退出应用账号不动服务器', () async {
      final relay = FakeRelay();
      final phone = Phone(relay);
      final first = await phone.signIn();
      final service = await phone.start();
      await service.enable('小红');
      final firstDevice = service.deviceId;
      final bob = await device(relay);
      await bob.enable('小明');
      await bob.redeem(InviteCode.decode((await service.createInvite()).encode())!);
      await service.refresh();
      expect(service.friends.single.nickname, '小明');

      final second = await phone.signIn();
      await service.switchAccount(second);
      expect(service.status, SocialStatus.disabled);
      expect(service.friends, isEmpty);
      await service.enable('小蓝');
      expect(service.deviceId, isNot(firstDevice));
      expect(relay.accountSocial[second.accountId], service.deviceId);

      await service.switchAccount(null);
      expect(service.status, SocialStatus.signedOut);
      expect(relay.accountSocial[first.accountId], firstDevice, reason: '退出应用账号不动服务器');
      await service.switchAccount(first);
      expect(service.status, SocialStatus.ready);
      expect(service.deviceId, firstDevice);
      expect(service.friends.single.nickname, '小明');
    });

    test('旧版留下的设备级私信（第 1 版的库、身份 identity）并进第一个用私信的应用账号：库升级、补挂一次，好友与会话都在；第二个账号另起一份', () async {
      final relay = FakeRelay();
      final phone = Phone(relay);
      // 旧版：设备级身份、注册过的设备、第 1 版的库（profile 没有 bound）。
      final legacy = await SocialIdentity.generate();
      phone.vault.identities['identity'] = legacy;
      relay.devices[legacy.deviceId] = (sign: legacy.signPublicKey, box: legacy.boxPublicKey);
      final old = await databaseFactory.openDatabase(path.join(phone.directory.path, SocialSpaces.legacyDatabase), options: OpenDatabaseOptions(version: 1, onCreate: (database, _) async {
        await database.execute('CREATE TABLE profile (id INTEGER PRIMARY KEY CHECK(id=1), nickname TEXT NOT NULL, registered INTEGER NOT NULL)');
        await database.execute("CREATE TABLE friend (device_id TEXT PRIMARY KEY, nickname TEXT NOT NULL, remark TEXT, sign_public_key TEXT NOT NULL, box_public_key TEXT NOT NULL, since TEXT NOT NULL, last_activity TEXT NOT NULL, removed INTEGER NOT NULL DEFAULT 0, last_preview TEXT NOT NULL DEFAULT '', unread INTEGER NOT NULL DEFAULT 0)");
        await database.execute('CREATE TABLE message (id TEXT PRIMARY KEY, friend_id TEXT NOT NULL, outgoing INTEGER NOT NULL, state TEXT NOT NULL, body TEXT, system TEXT, error TEXT, create_time TEXT NOT NULL)');
        await database.execute('CREATE TABLE invite (invite_id TEXT PRIMARY KEY, public_key TEXT NOT NULL, create_time TEXT NOT NULL)');
      }));
      await old.insert('profile', {'id': 1, 'nickname': '老用户', 'registered': 1});
      await old.insert('friend', {'device_id': 'friend-0001', 'nickname': '老朋友', 'sign_public_key': 'k', 'box_public_key': 'k', 'since': '2026-10-01T00:00:00.000Z', 'last_activity': '2026-10-01T00:00:00.000Z'});
      await old.close();

      final first = await phone.signIn();
      final service = await phone.start();
      expect(service.status, SocialStatus.ready);
      expect(service.deviceId, legacy.deviceId);
      expect(service.profile!.nickname, '老用户');
      expect(service.friends.single.nickname, '老朋友');
      expect(relay.accountSocial[first.accountId], legacy.deviceId);
      expect((await (await phone.store()).profile())!.bound, isTrue);

      await service.switchAccount(await phone.signIn());
      expect(service.status, SocialStatus.disabled, reason: '第二个账号另起一份');
      expect(phone.vault.owner, first.accountId);
    });

    test('换手机：新手机开启时私信在另一台上，确认后接管——好友名单与公钥从服务器来，好友核对后改挂、提示换了设备并发来昵称；旧手机停用，可以再接管回去', () async {
      final relay = FakeRelay();
      final oldPhone = Phone(relay);
      final account = await oldPhone.signIn();
      final before = await oldPhone.start();
      await before.enable('小红');
      final bob = await device(relay);
      await bob.enable('小明');
      await bob.redeem(InviteCode.decode((await before.createInvite()).encode())!);
      await before.refresh();
      await bob.send(before.deviceId!, sampleSchedule());

      final newPhone = Phone(relay);
      await newPhone.signIn(accountId: account.accountId);
      final after = await newPhone.start();
      await expectLater(after.enable('小红'), throwsA(isA<SocialException>().having((error) => error.code, 'code', RelayCode.socialElsewhere)));
      expect(after.status, SocialStatus.elsewhere);
      await after.takeOver();
      expect(after.status, SocialStatus.ready);
      expect(relay.accountSocial[account.accountId], after.deviceId);
      expect(after.friends.single.deviceId, bob.deviceId);
      expect(after.friends.single.nickname, placeholderNickname(bob.deviceId!), reason: '昵称只在密文里，等对方发来');
      expect(relay.mailbox.where((item) => item.recipient == before.deviceId), isEmpty, reason: '旧手机没收的信随旧设备删掉');

      await bob.refresh(reconcile: true);
      expect(bob.friends.single.deviceId, after.deviceId);
      expect(bob.friends.single.nickname, '小红', reason: '备注与昵称留着');
      final conversation = await bob.conversation(after.deviceId!);
      expect(conversation.first.system, 'friend_moved');
      expect(conversation.where((message) => message.card != null), hasLength(1), reason: '会话跟着改挂');
      expect(relay.movedFrom, isEmpty, reason: '处理完就确认');
      await after.refresh();
      expect(after.friends.single.nickname, '小明');
      expect(after.unread, 0, reason: '资料不算新内容');
      expect((await after.send(bob.deviceId!, sampleSchedule())).state, MessageState.sent);
      await bob.refresh();
      expect(bob.unread, 1);

      // 旧手机：下一次请求被拒，重新挂账号得到「在另一台手机上」，停用；可以再接管回去。
      await before.refresh();
      expect(before.status, SocialStatus.elsewhere);
      await before.takeOver();
      expect(before.status, SocialStatus.ready);
      expect(before.friends.single.deviceId, bob.deviceId);
      await bob.refresh(reconcile: true);
      expect(bob.friends.single.deviceId, before.deviceId);
      await after.refresh();
      expect(after.status, SocialStatus.elsewhere);
    });

    test('好友换了设备、这边还没核对：发过去被拒时先核对，改挂后报「对方换了设备」，点重发就到新设备；收到新设备的卡片先核对再收下', () async {
      final relay = FakeRelay();
      final oldPhone = Phone(relay);
      final account = await oldPhone.signIn();
      final alice = await oldPhone.start();
      await alice.enable('小红');
      final bob = await device(relay), carol = await device(relay);
      await bob.enable('小明');
      await carol.enable('小青');
      await bob.redeem(InviteCode.decode((await alice.createInvite()).encode())!);
      await carol.redeem(InviteCode.decode((await alice.createInvite()).encode())!);
      final newPhone = Phone(relay);
      await newPhone.signIn(accountId: account.accountId);
      final moved = await newPhone.start();
      await expectLater(moved.enable('小红'), throwsA(isA<SocialException>()));
      await moved.takeOver();

      final rejected = await bob.send(alice.deviceId!, sampleSchedule());
      expect(rejected.error, SocialCode.friendMoved);
      expect(bob.friends.single.removed, isFalse);
      expect((await bob.retry(rejected.id)).state, MessageState.sent);

      await moved.send(carol.deviceId!, sampleSchedule());
      await carol.refresh();
      expect(carol.friends.single.deviceId, moved.deviceId);
      expect(carol.unread, 1);
    });

    test('注销应用账号：清掉这台手机上那个账号的私信，停用；别的账号的不动', () async {
      final relay = FakeRelay();
      final phone = Phone(relay);
      final first = await phone.signIn();
      final service = await phone.start();
      await service.enable('小红');
      final second = await phone.signIn();
      await service.switchAccount(second);
      await service.enable('小蓝');
      await service.switchAccount(first);
      await service.forgetAccount(first);
      expect(service.status, SocialStatus.signedOut);
      expect(await (await phone.store(first)).profile(), isNull);
      expect(await phone.identity(first), isNull);
      expect(await phone.identity(second), isNotNull);
    });

    test('中转说应用账号已不在：停用私信、让应用账号马上核一次', () async {
      final relay = FakeRelay();
      final phone = Phone(relay);
      await phone.signIn();
      final service = await phone.start();
      await service.enable('小红');
      relay.accountDevices.clear();
      relay.devices.remove(service.deviceId);
      await service.refresh();
      expect(service.status, SocialStatus.signedOut);
      expect(phone.gone, 1);
      expect(service.refreshError, SocialCode.signedOut);
    });
  });
}

// 每次都给同一个值，数得出用了几次。
class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final double value;
  int calls = 0;
  @override
  double nextDouble() {
    calls++;
    return value;
  }

  @override
  bool nextBool() => value >= 0.5;
  @override
  int nextInt(int max) => (value * max).floor();
}
