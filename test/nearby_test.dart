import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/device/ble_nearby_radio.dart';
import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/nearby_radio.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/relay/relay_crypto.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/nearby_protocol.dart';
import 'package:superxd/social/nearby_service.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_store.dart';

import 'fake_nearby_radio.dart';
import 'share_card_test.dart' show sampleSchedule;

late Directory temporary;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => temporary = Directory.systemTemp.createTempSync('nearby_test'));
  tearDown(() => temporary.deleteSync(recursive: true));

  group('出现标记', () {
    test('好友认得出，别人只看到随机字节，每次随机数不同', () async {
      final me = await RelayIdentity.generate(), other = await RelayIdentity.generate();
      final key = presenceKeyOf(me.signPublicKey);
      final first = buildPresence(presenceKey: key), second = buildPresence(presenceKey: key);
      expect(first.length, presenceLength);
      expect(first, isNot(second));
      expect(presenceFriend(first, {'me': key}), 'me');
      expect(presenceFriend(second, {'other': presenceKeyOf(other.signPublicKey), 'me': key}), 'me');
      expect(presenceFriend(first, {'other': presenceKeyOf(other.signPublicKey)}), isNull);
      // 不带公钥与设备号。
      final text = String.fromCharCodes(first);
      expect(text.contains(me.deviceId), isFalse);
    });

    test('二维码标记只在出示这张码时对得上；长度或版本不对算不认识', () {
      final key = presenceKeyOf(Uint8List(32));
      final seed = secureRandomBytes(32);
      expect(presenceShows(buildPresence(presenceKey: key, inviteSeed: seed), seed), isTrue);
      expect(presenceShows(buildPresence(presenceKey: key, inviteSeed: secureRandomBytes(32)), seed), isFalse);
      expect(presenceShows(buildPresence(presenceKey: key), seed), isFalse);
      final presence = buildPresence(presenceKey: key);
      expect(presenceFriend(Uint8List.fromList([2, ...presence.sublist(1)]), {'me': key}), isNull);
      expect(presenceFriend(presence.sublist(0, 20), {'me': key}), isNull);
    });

    test('面对面二维码与线上二维码互不相认', () async {
      final identity = await RelayIdentity.generate();
      final code = InviteCode(
        inviteId: base64UrlNoPad(secureRandomBytes(16)),
        inviteSeed: secureRandomBytes(32),
        owner: PeerKeys(identity.signPublicKey, identity.boxPublicKey),
        nickname: '甲',
        expiresAt: 1,
        prefix: nearbyInvitePrefix,
      );
      final text = code.encode();
      expect(text.startsWith(nearbyInvitePrefix), isTrue);
      expect(InviteCode.decode(text), isNull);
      expect(InviteCode.decode(text, prefix: nearbyInvitePrefix)?.nickname, '甲');
    });
  });

  group('帧', () {
    test('按帧长切开再拼回原样，各种长度', () {
      for (final length in [1, 7, 8, 100, 506, 507, 508, 4096, 50000]) {
        for (final size in [20, 182, 512]) {
          final payload = Uint8List.fromList(List.generate(length, (index) => index % 251));
          final frames = nearbyFrames(payload, size);
          expect(frames.every((frame) => frame.length <= size), isTrue);
          final assembler = NearbyAssembler();
          Uint8List? whole;
          for (var index = 0; index < frames.length; index++) {
            whole = assembler.add(frames[index]);
            expect(whole == null, index < frames.length - 1);
          }
          expect(whole, payload);
        }
      }
    });

    test('没有首帧、超长、类型不对、拼到一半太久都作废', () {
      final assembler = NearbyAssembler();
      expect(() => assembler.add(Uint8List.fromList([2, 1, 2])), throwsFormatException);
      expect(() => assembler.add(Uint8List.fromList([9])), throwsFormatException);
      expect(() => assembler.add(Uint8List.fromList([1, 0, 0, 0, 0])), throwsFormatException);
      final tooLong = ByteData(5)..setUint8(0, 1)..setUint32(1, nearbyPayloadLimit + 1);
      expect(() => assembler.add(tooLong.buffer.asUint8List()), throwsFormatException);
      final declared = ByteData(5)..setUint8(0, 1)..setUint32(1, 2);
      expect(() => assembler.add(Uint8List.fromList([...declared.buffer.asUint8List(), 1, 2, 3])), throwsFormatException);
      var now = DateTime(2026);
      final slow = NearbyAssembler(clock: () => now);
      final frames = nearbyFrames(Uint8List(100), 20);
      slow.add(frames[0]);
      now = now.add(const Duration(seconds: 31));
      expect(() => slow.add(frames[1]), throwsFormatException);
    });
  });

  group('面对面私信', () {
    test('扫码互加好友，在附近时互发卡片，对方不在附近时记失败、回来后重发', () async {
      final hub = FakeNearbyHub();
      final a = NearbyPhone(hub, 'a', temporary), b = NearbyPhone(hub, 'b', temporary);
      await a.ready('甲');
      await b.ready('乙');
      await befriend(a, b);
      expect(a.service.friends.single.nickname, '乙');
      expect(b.service.friends.single.nickname, '甲');
      final aId = (await a.vault.read(NearbyService.identityKey))!.deviceId, bId = (await b.vault.read(NearbyService.identityKey))!.deviceId;
      expect(a.service.present.keys, [bId]);
      expect(b.service.present.keys, [aId]);

      final sent = await b.service.send(aId, sampleSchedule());
      expect(sent.state, MessageState.sent);
      final received = await a.service.conversation(a.service.friends.single.deviceId);
      expect(received.first.card, isA<ScheduleShare>());
      expect(a.service.friends.single.unread, 1);

      // 甲离开面对面页：乙那边不在附近，发送记失败；甲回来后重发成功、甲按消息号只收一次。
      a.service.release();
      await pumpEventQueue();
      expect(b.service.present, isEmpty);
      final failed = await b.service.send(aId, const VideoShare(sourceUrl: 'https://v.douyin.com/abc/', title: '视频', author: '作者', platform: 'douyin', kind: 'video'));
      expect(failed.state, MessageState.failed);
      expect(failed.error, SocialCode.nearbyAbsent);
      a.service.acquire();
      await pumpEventQueue();
      final retried = await b.service.retry(failed.id);
      expect(retried.state, MessageState.sent);
      expect((await a.service.conversation(a.service.friends.single.deviceId)).where((message) => message.card is VideoShare), hasLength(1));
    });

    test('删了好友后对方发来的不收下；二维码收起后扫码加不上', () async {
      final hub = FakeNearbyHub();
      final a = NearbyPhone(hub, 'a', temporary), b = NearbyPhone(hub, 'b', temporary), c = NearbyPhone(hub, 'c', temporary);
      await a.ready();
      await b.ready();
      await c.ready();
      await befriend(a, b);
      final aId = (await a.vault.read(NearbyService.identityKey))!.deviceId;
      await a.service.removeFriend(a.service.friends.single.deviceId);
      final rejected = await b.service.send(aId, sampleSchedule());
      expect(rejected.error, anyOf(SocialCode.nearbyRejected, SocialCode.nearbyAbsent));

      final code = await a.service.createInvite();
      a.radio.touch();
      await a.service.revokeInvite(code.inviteId);
      a.radio.touch();
      await expectLater(c.service.redeem(code), throwsA(isA<SocialException>().having((error) => error.code, 'code', SocialCode.nearbyAbsent)));
      expect(a.service.friends, isEmpty);
      expect(c.service.friends, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('扫自己的码、过期的码、蓝牙没开好时都直接说明', () async {
      final hub = FakeNearbyHub();
      final a = NearbyPhone(hub, 'a', temporary), b = NearbyPhone(hub, 'b', temporary);
      await a.ready();
      final own = await a.service.createInvite();
      await expectLater(a.service.redeem(own), throwsA(isA<SocialException>().having((error) => error.code, 'code', SocialCode.inviteSelf)));
      b.radio.startAs = NearbyRadioState.denied;
      await b.ready();
      expect(b.service.radioState, NearbyRadioState.denied);
      await expectLater(b.service.redeem(own), throwsA(isA<SocialException>().having((error) => error.code, 'code', SocialCode.nearbyOff)));
      final old = InviteCode(inviteId: own.inviteId, inviteSeed: own.inviteSeed, owner: own.owner, nickname: own.nickname, expiresAt: DateTime.now().subtract(const Duration(minutes: 2)).millisecondsSinceEpoch, prefix: nearbyInvitePrefix);
      await expectLater(b.service.redeem(old), throwsA(isA<SocialException>().having((error) => error.code, 'code', SocialCode.inviteExpired)));
    });

    test('并进应用账号：问一次，并进的只在这个账号下看得到、收发也只认这个账号；注销时删掉', () async {
      final hub = FakeNearbyHub();
      final a = NearbyPhone(hub, 'a', temporary), b = NearbyPhone(hub, 'b', temporary), c = NearbyPhone(hub, 'c', temporary);
      await a.ready();
      await b.ready();
      await c.ready();
      await befriend(a, b);
      expect(await a.service.pendingMerge(), isNull);
      await a.service.setAccount('account-x');
      expect(await a.service.pendingMerge(), 1);
      await a.service.chooseMerge(merge: true);
      expect(await a.service.pendingMerge(), isNull);
      expect(a.service.friends.single.owner, 'account-x');
      // 这个账号下新加的也归它。
      await befriend(a, c);
      expect(a.service.friends.map((friend) => friend.owner), everyElement('account-x'));

      // 换成别的账号或退出：看不到，也不收它们发来的。
      await a.service.setAccount('account-y');
      expect(a.service.friends, isEmpty);
      expect(await a.service.pendingMerge(), isNull);
      final aId = (await a.vault.read(NearbyService.identityKey))!.deviceId;
      final blocked = await b.service.send(aId, sampleSchedule());
      expect(blocked.state, MessageState.failed);
      await a.service.setAccount(null);
      expect(a.service.friends, isEmpty);

      await a.service.setAccount('account-x');
      expect(a.service.friends, hasLength(2));
      await a.service.forgetAccount('account-x');
      expect(a.service.friends, isEmpty);
    });

    test('不并：仍是这台手机自己的，谁登录都看得到，不再问', () async {
      final hub = FakeNearbyHub();
      final a = NearbyPhone(hub, 'a', temporary), b = NearbyPhone(hub, 'b', temporary);
      await a.ready();
      await b.ready();
      await befriend(a, b);
      await a.service.setAccount('account-x');
      await a.service.chooseMerge(merge: false);
      expect(await a.service.pendingMerge(), isNull);
      expect(a.service.friends.single.owner, isNull);
      await a.service.setAccount('account-y');
      expect(a.service.friends, hasLength(1));
      await a.service.setAccount(null);
      expect(a.service.friends, hasLength(1));
    });

    test('身份丢了就清空面对面数据回到设昵称；删除面对面数据清身份与好友', () async {
      final hub = FakeNearbyHub();
      final a = NearbyPhone(hub, 'a', temporary), b = NearbyPhone(hub, 'b', temporary);
      await a.ready();
      await b.ready();
      await befriend(a, b);
      await b.service.clearAll();
      expect(b.service.status, NearbyStatus.setup);
      expect(b.service.friends, isEmpty);
      expect(await b.vault.read(NearbyService.identityKey), isNull);
      expect(b.radio.state, NearbyRadioState.off);

      await a.vault.delete(NearbyService.identityKey);
      final again = NearbyPhone(hub, 'a', temporary);
      again.vault.identities.addAll(a.vault.identities);
      await again.service.open();
      expect(again.service.status, NearbyStatus.setup);
      expect(again.service.friends, isEmpty);
    });

    test('离开面对面页就停蓝牙，设好昵称前不开', () async {
      final hub = FakeNearbyHub();
      final a = NearbyPhone(hub, 'a', temporary);
      await a.service.open();
      a.service.acquire();
      await pumpEventQueue();
      expect(a.radio.state, NearbyRadioState.off);
      await a.service.enable('甲');
      await pumpEventQueue();
      expect(a.radio.state, NearbyRadioState.ready);
      a.service.release();
      await pumpEventQueue();
      expect(a.radio.state, NearbyRadioState.off);
    });
  });

  test('线上私信的旧库升级到第 3 版：好友多出归属一列、全为空', () async {
    final file = path.join(temporary.path, 'old.db');
    final old = await databaseFactory.openDatabase(file, options: OpenDatabaseOptions(version: 2, onCreate: (database, _) async {
      await database.execute('CREATE TABLE profile (id INTEGER PRIMARY KEY CHECK(id=1), nickname TEXT NOT NULL, registered INTEGER NOT NULL, bound INTEGER NOT NULL DEFAULT 0)');
      await database.execute('CREATE TABLE friend (device_id TEXT PRIMARY KEY, nickname TEXT NOT NULL, remark TEXT, sign_public_key TEXT NOT NULL, box_public_key TEXT NOT NULL, since TEXT NOT NULL, last_activity TEXT NOT NULL, removed INTEGER NOT NULL DEFAULT 0, last_preview TEXT NOT NULL DEFAULT \'\', unread INTEGER NOT NULL DEFAULT 0)');
      await database.execute('CREATE TABLE message (id TEXT PRIMARY KEY, friend_id TEXT NOT NULL, outgoing INTEGER NOT NULL, state TEXT NOT NULL, body TEXT, system TEXT, error TEXT, create_time TEXT NOT NULL)');
      await database.execute('CREATE TABLE invite (invite_id TEXT PRIMARY KEY, public_key TEXT NOT NULL, create_time TEXT NOT NULL)');
      await database.insert('friend', {'device_id': 'd1', 'nickname': '丙', 'sign_public_key': 's', 'box_public_key': 'b', 'since': 't', 'last_activity': 't'});
    }));
    await old.close();
    final store = await SocialStore.open(file);
    expect((await store.friends()).single.owner, isNull);
    expect(await store.ownerChoice('x'), isNull);
    await store.close();
  });
}
