import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/nearby_radio.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/page/conversation_page.dart';
import 'package:superxd/page/message_page.dart';
import 'package:superxd/page/nearby_page.dart';
import 'package:superxd/page/share_target_sheet.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_spaces.dart';

import 'fake_nearby_radio.dart';
import 'fake_relay.dart';
import 'share_card_test.dart' show sampleSchedule;
import 'social_ui_test.dart' show advance, advanceUntil, app;

late Directory temporary;

// 面对面私信页（人工决策见 social/nearby_service.dart）：入口、设昵称、蓝牙状态、在不在附近、并进账号、分享弹层与发卡片。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => temporary = Directory.systemTemp.createTempSync('nearby_ui'));
  tearDown(() => temporary.deleteSync(recursive: true));

  Future<(NearbyPhone, NearbyPhone)> pair(WidgetTester tester) async => (await tester.runAsync(() async {
    final hub = FakeNearbyHub();
    final a = NearbyPhone(hub, 'a', temporary), b = NearbyPhone(hub, 'b', temporary);
    await a.ready('小红');
    await b.ready('小明');
    await befriend(a, b);
    return (a, b);
  }))!;

  testWidgets('消息页顶栏的「面对面」没配中转也在；第一次设昵称后开蓝牙，写明在找附近的好友', (tester) async {
    final phone = NearbyPhone(FakeNearbyHub(), 'a', temporary);
    await tester.pumpWidget(app(Scaffold(body: MessagePage(nearby: phone.service))));
    await advance(tester);
    expect(find.text('当前版本未配置私信服务'), findsOneWidget);
    await tester.tap(find.byTooltip('面对面'));
    await advanceUntil(tester, () => find.text('面对面私信').evaluate().isNotEmpty);
    expect(find.text('隐私政策'), findsOneWidget);
    expect(phone.radio.state, NearbyRadioState.off);
    await tester.tap(find.text('同意并开始'));
    await advance(tester, 3);
    expect(find.textContaining('昵称为 1–20 个字'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '小红');
    await tester.tap(find.text('同意并开始'));
    await advanceUntil(tester, () => find.text('添加好友').evaluate().isNotEmpty);
    expect(phone.radio.state, NearbyRadioState.ready);
    expect(find.text('正在找附近打开面对面的好友'), findsOneWidget);
    expect(find.textContaining('还没有面对面好友'), findsOneWidget);
    // 离开面对面页就停蓝牙。
    await tester.tap(find.byTooltip('返回'));
    await advance(tester);
    expect(phone.radio.state, NearbyRadioState.off);
  });

  testWidgets('没给蓝牙权限时原地写明并给「去设置」', (tester) async {
    final phone = NearbyPhone(FakeNearbyHub(), 'a', temporary)..radio.startAs = NearbyRadioState.denied;
    await tester.runAsync(() async {
      await phone.service.open();
      await phone.service.enable('小红');
    });
    await tester.pumpWidget(app(NearbyPage(nearby: phone.service)));
    await advanceUntil(tester, () => find.text('没有蓝牙权限').evaluate().isNotEmpty);
    expect(find.text('去设置'), findsOneWidget);
  });

  testWidgets('好友在附近时那一行写「在附近」，点开是同一个会话页', (tester) async {
    final (a, _) = await pair(tester);
    await tester.pumpWidget(app(NearbyPage(nearby: a.service)));
    await advanceUntil(tester, () => find.text('小明').evaluate().isNotEmpty);
    expect(find.text('附近有 1 位好友'), findsOneWidget);
    expect(find.textContaining('在附近'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('小明，在附近')), findsOneWidget);
    await tester.tap(find.text('小明'));
    await advanceUntil(tester, () => find.byType(ConversationPage).evaluate().isNotEmpty);
    expect(find.text('已成为好友'), findsOneWidget);
  });

  testWidgets('登录应用账号后第一次打开问一次并进，只能二选一；选了就不再问', (tester) async {
    final (a, _) = await pair(tester);
    await tester.runAsync(() => a.service.setAccount('account-x'));
    await tester.pumpWidget(app(NearbyPage(nearby: a.service)));
    await advanceUntil(tester, () => find.text('把 1 位面对面好友并进这个账号？').evaluate().isNotEmpty);
    expect(find.text('不并'), findsOneWidget);
    await tester.tap(find.text('并进'));
    await advanceUntil(tester, () => a.service.friends.isNotEmpty && a.service.friends.single.owner == 'account-x');
    expect(await tester.runAsync(a.service.pendingMerge), isNull);
  });

  testWidgets('从分享弹层来：点在附近的好友直接发这张卡，原地写已发送', (tester) async {
    final (a, b) = await pair(tester);
    await tester.pumpWidget(app(NearbyPage(nearby: a.service, card: sampleSchedule())));
    await advanceUntil(tester, () => find.text('小明').evaluate().isNotEmpty);
    expect(find.text('面对面发送'), findsOneWidget);
    await tester.tap(find.text('小明'));
    await advanceUntil(tester, () => find.text('已发送').evaluate().isNotEmpty);
    final received = (await tester.runAsync(() => b.service.conversation(b.service.friends.single.deviceId)))!;
    expect(received.first.card, isA<ScheduleShare>());
  });

  testWidgets('分享弹层：有面对面时私信没登录也打开弹层，上面是面对面发送，下面写原因与去登录', (tester) async {
    final opened = <String>[];
    ShareCard? nearbyCard;
    final social = (await tester.runAsync(() async {
      final directory = Directory(path.join(temporary.path, 'share'))..createSync();
      final social = SocialService(spaces: SocialSpaces(vault: MemoryIdentityVault(), directory: directory.path), accountKeys: MemoryAppAccountVault(), transport: FakeRelay().transport(), serverKeys: FakeRelay.serverKeys);
      await social.switchAccount(null);
      return social;
    }))!;
    final card = sampleSchedule();
    await tester.pumpWidget(app(ShareGuide(
      openAccount: (_) => opened.add('account'),
      openMessages: (_) => opened.add('messages'),
      openNearby: (_, shared) => nearbyCard = shared,
      child: Scaffold(body: Builder(builder: (context) => Center(child: TextButton(onPressed: () => showShareSheet(context, social: social, card: card), child: const Text('打开分享'))))),
    )));
    await tester.tap(find.text('打开分享'));
    await advance(tester, 6);
    expect(find.text('面对面发送'), findsOneWidget);
    expect(find.text('先登录应用账号'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);
    await tester.tap(find.text('面对面发送'));
    await advance(tester, 4);
    expect(nearbyCard, same(card));
    await tester.tap(find.text('打开分享'));
    await advance(tester, 6);
    await tester.tap(find.text('去登录'));
    await advance(tester, 4);
    expect(opened, ['account']);
  });
}
