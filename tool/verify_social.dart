import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_store.dart';

// 私信端到端联调（手动，不进 CI）：两个真实客户端经真实中转服务加好友、收发三种卡片、删除好友、关闭私信。
// 只用合成数据。运行：
//   flutter test tool/verify_social.dart --dart-define=SUPERXD_RELAY=http://127.0.0.1:18080
// 中转服务可用 server/docker-compose.test.yml 起库后 npm run build && node dist/main.js 启动，或指向已部署的服务器。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('真实中转服务：扫码加好友、收发卡片、删除好友、关闭私信', () async {
    expect(relayBaseUrl, isNotEmpty, reason: '用 --dart-define=SUPERXD_RELAY=… 指定中转服务地址');
    final directory = Directory.systemTemp.createTempSync('verify_social');
    Future<SocialService> device(String name) async {
      final service = SocialService(store: await SocialStore.open(path.join(directory.path, '$name.db')), vault: MemoryIdentityVault(), transport: HttpRelayTransport(relayBaseUrl));
      await service.initialize();
      await service.enable(name);
      return service;
    }

    final alice = await device('联调甲'), bob = await device('联调乙');
    final watch = Stopwatch()..start();
    await bob.redeem(InviteCode.decode((await alice.createInvite()).encode())!);
    await alice.refresh(reconcile: true);
    expect(alice.friends.single.nickname, '联调乙');
    expect(bob.friends.single.nickname, '联调甲');
    stdout.writeln('[VerifySocial] pair_ms=${watch.elapsedMilliseconds}');

    final schedule = ScheduleShare(
      term: const TermRef(xn: '2026', xq: '0', label: '合成学期'),
      termStartDate: '2026-09-07',
      courses: [
        for (var index = 0; index < 60; index++)
          CourseRecord(courseCode: 'C$index', courseName: '合成课程$index', sectionId: 'S$index', credit: 2, teacherName: '合成教师', meetings: [CourseMeeting(weekday: index % 5 + 1, periodStart: index % 10 + 1, periodEnd: index % 10 + 2, place: '合成教室$index', weeks: List.generate(16, (week) => week + 1))]),
      ],
      bells: [for (var period = 1; period <= 12; period++) BellPeriod(period: period, dayPart: '', dayPartCode: '', start: '${(7 + period).toString().padLeft(2, '0')}:00', end: '${(7 + period).toString().padLeft(2, '0')}:45')],
    );
    final cards = <ShareCard>[
      schedule,
      const AppearanceShare(paletteId: 'mist', fontId: 'serif', scale: 1.1, themeMode: 'dark', glassMode: 'auto', wallpaperBlur: 27, wallpaperFade: 0),
      const VideoShare(sourceUrl: 'https://example.com/synthetic', title: '合成作品', author: '合成作者', platform: 'example', kind: 'video'),
    ];
    watch.reset();
    for (final card in cards) {
      expect((await bob.send(alice.deviceId!, card)).state, MessageState.sent);
    }
    stdout.writeln('[VerifySocial] send3_ms=${watch.elapsedMilliseconds}');
    watch.reset();
    await alice.refresh();
    stdout.writeln('[VerifySocial] fetch_ms=${watch.elapsedMilliseconds}');
    final received = (await alice.conversation(bob.deviceId!)).where((message) => message.card != null).toList();
    expect(received.map((message) => message.card!.type), unorderedEquals(['schedule', 'appearance', 'video']));
    expect((received.firstWhere((message) => message.card is ScheduleShare).card! as ScheduleShare).courses, hasLength(60));
    expect(alice.unread, 3);

    // 长轮询：alice 挂着拉取，bob 一秒后发一张，看 alice 多久拿到（应远小于挂起时长）。
    final aliceIdentity = await alice.vault.read();
    final relay = RelayClient(HttpRelayTransport(relayBaseUrl));
    final waiting = relay.fetch(aliceIdentity!, wait: SocialService.longPollWait);
    await Future<void>.delayed(const Duration(seconds: 1));
    final sentAt = DateTime.now();
    await bob.send(alice.deviceId!, cards.last);
    final woken = await waiting;
    stdout.writeln('[VerifySocial] long_poll_wake_ms=${DateTime.now().difference(sentAt).inMilliseconds} items=${woken.messages.length}');
    expect(woken.messages, hasLength(1));
    await alice.refresh();

    await alice.removeFriend(bob.deviceId!);
    expect((await bob.send(alice.deviceId!, cards.last)).error, RelayCode.notFriend);
    await alice.disable();
    await bob.disable();
    directory.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
