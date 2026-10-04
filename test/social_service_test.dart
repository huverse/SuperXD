import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/share_card.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_store.dart';

import 'fake_relay.dart';
import 'share_card_test.dart' show sampleSchedule;

late Directory temporary;
var _databases = 0;

Future<SocialService> device(FakeRelay? relay, {MemoryIdentityVault? vault, String? databasePath, bool polling = false}) async {
  final store = await SocialStore.open(databasePath ?? path.join(temporary.path, 'social_${_databases++}.db'));
  final service = SocialService(store: store, vault: vault ?? MemoryIdentityVault(), transport: relay?.transport(), polling: polling);
  await service.initialize();
  return service;
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

  test('开启：生成身份、注册、保存昵称；昵称不合规拒绝', () async {
    final relay = FakeRelay();
    final service = await device(relay);
    expect(service.status, SocialStatus.disabled);
    expect(() => service.enable(' 空格'), throwsArgumentError);
    await service.enable('小红');
    expect(service.status, SocialStatus.ready);
    expect(relay.devices.keys, [service.deviceId]);
    expect((await service.store.profile())!.registered, isTrue);
  });

  test('注册失败时保留身份与昵称，下次启动补注册', () async {
    final relay = FakeRelay();
    final vault = MemoryIdentityVault();
    final databasePath = path.join(temporary.path, 'retry.db');
    final first = await device(relay, vault: vault, databasePath: databasePath);
    relay.failNext = const RelayException(RelayCode.network);
    await expectLater(first.enable('小红'), throwsA(isA<SocialException>().having((error) => error.code, 'code', RelayCode.network)));
    expect(first.status, SocialStatus.disabled);
    await first.store.close();
    final second = await device(relay, vault: vault, databasePath: databasePath);
    expect(second.status, SocialStatus.ready);
    expect(relay.devices.keys, [vault.identity!.deviceId]);
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
    final fakeSeed = randomBytes(32);
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
    await alice.store.deleteFriend(bob.deviceId!);
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
    expect(relay.calls.where((call) => call == 'POST /v1/devices'), hasLength(2));
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
      await bob.store.addCard(id: 'id-${index.toString().padLeft(4, '0')}', friendId: alice.deviceId!, outgoing: true, state: MessageState.sent, card: sampleSchedule(), now: DateTime.now().toUtc().add(Duration(seconds: index + 1)).toIso8601String());
    }
    final kept = await bob.conversation(alice.deviceId!);
    expect(kept, hasLength(conversationLimit));
    expect(kept.first.id, 'id-0204');
    expect(kept.any((message) => message.system == 'friend_added'), isFalse);
  });

  test('关闭私信：服务端删除设备与关系，本机清空库与身份', () async {
    final relay = FakeRelay();
    final (alice, bob) = await friendsPair(relay);
    final vault = MemoryIdentityVault();
    final carol = await device(relay, vault: vault);
    await carol.enable('小青');
    final carolId = carol.deviceId;
    await carol.disable();
    expect(carol.status, SocialStatus.disabled);
    expect(carol.deviceId, isNull);
    expect(relay.devices.containsKey(carolId), isFalse);
    expect(vault.identity, isNull);
    expect(await carol.store.profile(), isNull);
    final aliceId = alice.deviceId!;
    await alice.disable();
    expect(relay.friends(bob.deviceId!, aliceId), isFalse);
  });

  test('身份丢失（安全存储被清）时回到未开启，清掉无法解密的旧数据', () async {
    final relay = FakeRelay();
    final vault = MemoryIdentityVault();
    final databasePath = path.join(temporary.path, 'lost.db');
    final first = await device(relay, vault: vault, databasePath: databasePath);
    await first.enable('小红');
    await first.store.close();
    vault.identity = null;
    final second = await device(relay, vault: vault, databasePath: databasePath);
    expect(second.status, SocialStatus.disabled);
    expect(await second.store.profile(), isNull);
  });

  test('启动时把中断的“发送中”改为失败，由用户重发', () async {
    final relay = FakeRelay();
    final vault = MemoryIdentityVault();
    final databasePath = path.join(temporary.path, 'interrupted.db');
    final first = await device(relay, vault: vault, databasePath: databasePath);
    await first.enable('小红');
    await first.store.addCard(id: 'pending', friendId: 'x', outgoing: true, state: MessageState.sending, card: sampleSchedule(), now: DateTime.now().toUtc().toIso8601String());
    await first.store.close();
    final second = await device(relay, vault: vault, databasePath: databasePath);
    expect((await second.store.message('pending'))!.state, MessageState.failed);
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
    final vault = MemoryIdentityVault();
    final databasePath = path.join(temporary.path, 'live.db');
    final bob = await device(relay);
    await bob.enable('小明');
    final first = await device(relay, vault: vault, databasePath: databasePath);
    await first.enable('小青');
    await bob.redeem(InviteCode.decode((await first.createInvite()).encode())!);
    await first.refresh();
    await first.store.close();
    // 重开为带长轮询的实例，第一次拉取就断网：退避 2 秒后应恢复并收到。
    relay.failNext = const RelayException(RelayCode.network);
    final resumed = await device(relay, vault: vault, databasePath: databasePath, polling: true);
    await bob.send(resumed.deviceId!, sampleSchedule());
    await eventually(() => resumed.unread == 1, timeout: const Duration(seconds: 8));
    resumed.dispose();
    relay.releaseWaiters();
  });
}
