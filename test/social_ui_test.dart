import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/conversation_page.dart';
import 'package:superxd/page/friend_add_page.dart';
import 'package:superxd/page/friend_schedule_page.dart';
import 'package:superxd/page/message_page.dart';
import 'package:superxd/page/share_target_sheet.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_store.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_refresh.dart';
import 'package:superxd/theme/campus_theme.dart';

import 'fake_relay.dart';
import 'share_card_test.dart' show sampleSchedule;

late Directory temporary;
var _databases = 0;

Future<SocialService> device(FakeRelay relay, [String? nickname]) async {
  final service = SocialService(store: await SocialStore.open(path.join(temporary.path, 'ui_${_databases++}.db')), vault: MemoryIdentityVault(), transport: relay.transport());
  await service.initialize();
  if (nickname != null) await service.enable(nickname);
  return service;
}

Future<(SocialService, SocialService)> friends(FakeRelay relay) async {
  final alice = await device(relay, '小红'), bob = await device(relay, '小明');
  await bob.redeem(InviteCode.decode((await alice.createInvite()).encode())!);
  await alice.refresh();
  return (alice, bob);
}

Widget app(Widget home, {DisplaySettings? display}) {
  final settings = display ?? DisplaySettings.memory();
  return ListenableBuilder(listenable: settings, builder: (context, _) => MaterialApp(
    theme: campusTheme(palette: CampusPalette.byId(settings.paletteId), fontFamily: settings.fontFamily),
    builder: (context, child) => DisplayScope(settings: settings, child: child!),
    home: home,
  ));
}

// 页面里的加载动画循环播放，不能 pumpAndSettle；按固定步长推进，让数据库与加密的异步完成。
Future<void> advance(WidgetTester tester, [int frames = 12]) async {
  for (var index = 0; index < frames; index++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

// 等真实异步（生成密钥、写库）完成再断言：固定帧数在 CI 慢磁盘上不够，上限只在失败时才会用满。
Future<void> advanceUntil(WidgetTester tester, bool Function() done) async {
  for (var tick = 0; tick < 1000 && !done(); tick++) {
    await advance(tester, 1);
  }
  expect(done(), isTrue);
  await advance(tester);
}

// 只实现好友课表页用到的读取方法。
class _MyScheduleGateway implements CampusGateway {
  _MyScheduleGateway(this.courses, {this.termStartDate});
  final List<CourseRecord> courses;
  final String? termStartDate;
  static const term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
  GatewayResult<T> _ok<T>(T data) => GatewayResult(ok: true, source: 'test', fetchedAt: '', data: data);
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => _ok([term]);
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async =>
      _ok(ScheduleView(term: term, student: const SessionView(loginId: 'me', name: '我', className: ''), courses: courses, termStartDate: termStartDate, revisionId: 'r1'));
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async => _ok(BellsView(empty: true, message: '', term: term, periods: const []));
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => temporary = Directory.systemTemp.createTempSync('social_ui'));
  tearDown(() => temporary.deleteSync(recursive: true));

  testWidgets('未开启时填昵称开启：昵称不合规原地提示，开启后显示添加好友', (tester) async {
    final relay = FakeRelay();
    final social = (await tester.runAsync(() => device(relay)))!;
    await tester.pumpWidget(app(Scaffold(body: MessagePage(social: social))));
    await advance(tester);
    expect(find.text('开启私信'), findsOneWidget);
    expect(find.text('隐私政策'), findsOneWidget);
    await tester.tap(find.text('同意并开启'));
    await advance(tester, 3);
    expect(find.textContaining('昵称为 1–20 个字'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '小红');
    await tester.tap(find.text('同意并开启'));
    await advanceUntil(tester, () => social.status == SocialStatus.ready && find.text('添加好友').evaluate().isNotEmpty);
    expect(find.text('添加好友'), findsOneWidget);
    expect(find.textContaining('还没有好友'), findsOneWidget);
  });

  testWidgets('好友列表：预览、未读角标；进入会话后清零，卡片按类型渲染', (tester) async {
    final relay = FakeRelay();
    final (alice, bob) = (await tester.runAsync(() => friends(relay)))!;
    await tester.runAsync(() async {
      await bob.send(alice.deviceId!, sampleSchedule());
      await bob.send(alice.deviceId!, const VideoShare(sourceUrl: 'https://v.example.com/1', title: '合成作品', author: '作者甲', platform: 'douyin', kind: 'video'));
      await alice.refresh();
    });
    await tester.pumpWidget(app(Scaffold(body: MessagePage(social: alice))));
    await advance(tester);
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('[视频] 合成作品'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('私信 2'), findsOneWidget);
    await tester.tap(find.text('小明'));
    // 进入会话后标记已读要写库，CI 曾在固定帧数内没写完（未读仍为 2）。
    await advanceUntil(tester, () => alice.unread == 0);
    expect(find.byType(ConversationPage), findsOneWidget);
    expect(find.text('2026-2027学年第一学期'), findsOneWidget);
    expect(find.text('合成作品'), findsOneWidget);
    expect(find.text('查看与对比'), findsOneWidget);
    expect(find.text('打开'), findsOneWidget);
    expect(find.textContaining('已成为好友'), findsOneWidget);
    expect(alice.unread, 0);
  });

  testWidgets('下拉刷新：应用自己的曲线指示随拉动描出，拉够即刷新收到新卡片，完成后收起；不用 Material 转圈', (tester) async {
    final relay = FakeRelay();
    final (alice, bob) = (await tester.runAsync(() => friends(relay)))!;
    await tester.pumpWidget(app(Scaffold(body: MessagePage(social: alice))));
    await advanceUntil(tester, () => find.text('小明').evaluate().isNotEmpty);
    await tester.runAsync(() => bob.send(alice.deviceId!, const VideoShare(sourceUrl: 'https://v.example.com/2', title: '新作品', author: '作者乙', platform: 'douyin', kind: 'video')));
    expect(find.text('[视频] 新作品'), findsNothing);
    final reveal = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is CurveRevealPainter);
    final rest = tester.getTopLeft(find.text('小明')).dy;
    final gesture = await tester.startGesture(tester.getCenter(find.text('小明')));
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    // 没拉够：只描出一部分曲线，还没有开始刷新。
    expect(reveal, findsOneWidget);
    final partial = (tester.widget<CustomPaint>(reveal).painter! as CurveRevealPainter).fraction;
    expect(partial, inExclusiveRange(0, 1));
    await gesture.moveBy(const Offset(0, 160));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(find.byType(CampusLoader), findsOneWidget);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await advanceUntil(tester, () => find.text('[视频] 新作品').evaluate().isNotEmpty);
    await advanceUntil(tester, () => find.byType(CampusLoader).evaluate().isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.getTopLeft(find.text('小明')).dy, closeTo(rest, .5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('界面配置卡片：套用立即生效，提示条撤销回到原样', (tester) async {
    final relay = FakeRelay();
    final display = DisplaySettings.memory();
    final (alice, bob) = (await tester.runAsync(() => friends(relay)))!;
    await tester.runAsync(() async {
      await bob.send(alice.deviceId!, const AppearanceShare(paletteId: 'mist', fontId: 'serif', scale: 1.1, themeMode: 'light', glassMode: 'reduced', wallpaperBlur: 50, wallpaperFade: 20));
      await alice.refresh();
    });
    await tester.pumpWidget(app(ConversationPage(social: alice, friendId: bob.deviceId!), display: display));
    await advance(tester);
    expect(find.textContaining('雾蓝'), findsOneWidget);
    await tester.tap(find.text('套用'));
    await advance(tester, 4);
    expect([display.paletteId, display.fontId, display.scale, display.themeMode, display.glassMode], ['mist', 'serif', 1.1, ThemeMode.light, 'reduced']);
    expect(find.text('已套用'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await advance(tester, 4);
    expect([display.paletteId, display.fontId, display.scale, display.themeMode], ['sage', 'maple', 1.0, ThemeMode.system]);
  });

  testWidgets('会话底栏分享界面：卡片原地显示已发送；对方删除好友后底栏禁用', (tester) async {
    final relay = FakeRelay();
    final (alice, bob) = (await tester.runAsync(() => friends(relay)))!;
    await tester.pumpWidget(app(ConversationPage(social: bob, friendId: alice.deviceId!)));
    await advance(tester);
    expect(find.text('分享课表'), findsNothing, reason: '没有教务网关时不提供分享课表');
    await tester.tap(find.text('分享界面'));
    await advanceUntil(tester, () => find.text('界面配置').evaluate().isNotEmpty);
    expect(find.text('界面配置'), findsOneWidget);
    expect(relay.mailbox, hasLength(1));
    await tester.runAsync(() async {
      await alice.removeFriend(bob.deviceId!);
      await bob.refresh(reconcile: true);
    });
    await advance(tester);
    expect(find.text('对方已解除好友，无法发送'), findsOneWidget);
    expect(find.text('分享界面'), findsNothing);
  });

  testWidgets('分享弹层：多选好友发送，每行原地显示已发送，按钮变为完成', (tester) async {
    final relay = FakeRelay();
    final (alice, bob) = (await tester.runAsync(() => friends(relay)))!;
    await tester.pumpWidget(app(Scaffold(body: Builder(builder: (context) => Center(child: TextButton(onPressed: () => showShareSheet(context, social: bob, card: sampleSchedule()), child: const Text('打开分享')))))));
    await tester.tap(find.text('打开分享'));
    await advance(tester, 6);
    expect(find.text('[课表] 2026-2027学年第一学期'), findsOneWidget);
    await tester.tap(find.text('小红'));
    await advance(tester, 2);
    await tester.tap(find.text('发送给 1 位好友'));
    await advanceUntil(tester, () => find.text('已发送').evaluate().isNotEmpty);
    expect(find.text('已发送'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(relay.mailbox.single.recipient, alice.deviceId);
  });

  testWidgets('分享弹层：未开启私信或没有好友时只提示，不弹列表', (tester) async {
    final relay = FakeRelay();
    final lonely = (await tester.runAsync(() => device(relay, '独行')))!;
    await tester.pumpWidget(app(Scaffold(body: Builder(builder: (context) => Center(child: TextButton(onPressed: () => showShareSheet(context, social: lonely, card: sampleSchedule()), child: const Text('打开分享')))))));
    await tester.tap(find.text('打开分享'));
    await advance(tester, 6);
    expect(find.textContaining('还没有好友'), findsOneWidget);
  });

  testWidgets('好友课表：默认共同空闲，按周列出双方都没课的时段', (tester) async {
    final share = ScheduleShare(
      term: _MyScheduleGateway.term,
      termStartDate: '2026-09-07',
      courses: [CourseRecord(courseCode: 'A', courseName: '高等数学', sectionId: '1', credit: 4, teacherName: '', meetings: [CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: '', weeks: [1, 2])])],
      bells: const [
        BellPeriod(period: 1, dayPart: '', dayPartCode: '', start: '08:00', end: '08:45'),
        BellPeriod(period: 2, dayPart: '', dayPartCode: '', start: '08:55', end: '09:40'),
        BellPeriod(period: 3, dayPart: '', dayPartCode: '', start: '10:00', end: '10:45'),
        BellPeriod(period: 4, dayPart: '', dayPartCode: '', start: '10:55', end: '11:40'),
      ],
    );
    final mine = [CourseRecord(courseCode: 'B', courseName: '大学英语', sectionId: '2', credit: 2, teacherName: '', meetings: [CourseMeeting(weekday: 1, periodStart: 3, periodEnd: 3, place: '', weeks: [1])])];
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(FriendSchedulePage(friendName: '小明', share: share, sharedAt: '2026-10-04T08:00:00.000Z', gateway: _MyScheduleGateway(mine, termStartDate: '2026-09-07'))));
    await advance(tester);
    // 第 1 周（今天在学期之后时取最后一周 2；先回到第 1 周）。
    // 学期只有两周，最多点一次就到；给个上限，翻不到时直接报出来，不让用例卡到整体超时。
    for (var step = 0; step < 20 && find.text('第 1 周').evaluate().isEmpty; step++) {
      await tester.tap(find.byTooltip('上一周'));
      await tester.pump();
    }
    expect(find.text('第 1 周'), findsOneWidget, reason: '翻回第 1 周');
    expect(find.text('本周共同空闲'), findsOneWidget);
    expect(find.text('周一 第4节 10:55–11:40'), findsOneWidget);
    expect(find.text('周二 第1–4节 08:00–11:40'), findsOneWidget);
    await tester.tap(find.text('TA的课表'));
    await tester.pump();
    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('本周共同空闲'), findsNothing);
  });

  testWidgets('添加好友：出示二维码带倒计时；对方一扫原地提示已添加；扫对方码后返回新好友', (tester) async {
    final relay = FakeRelay();
    final alice = (await tester.runAsync(() => device(relay, '小红')))!;
    final bob = (await tester.runAsync(() => device(relay, '小明')))!;
    final carol = (await tester.runAsync(() => device(relay, '小青')))!;
    final carolCode = (await tester.runAsync(() => carol.createInvite()))!;
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? result;
    await tester.pumpWidget(app(Builder(builder: (context) => Center(child: TextButton(
      onPressed: () async => result = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => FriendAddPage(social: alice, scan: (_) async => carolCode))),
      child: const Text('打开'),
    )))));
    await tester.tap(find.text('打开'));
    await advance(tester);
    expect(find.bySemanticsLabel(RegExp('我的好友二维码')), findsOneWidget);
    expect(find.byType(PrettyQrView), findsOneWidget);
    expect(find.textContaining('后失效'), findsOneWidget);
    // bob 扫码加 alice（二维码编码本身由 social_protocol_test 覆盖）：问候到达后（应用里由长轮询送达，这里手动拉一次）原地提示。
    await tester.runAsync(() async {
      await bob.redeem(InviteCode.decode((await alice.createInvite()).encode())!);
      await alice.refresh();
    });
    await advance(tester);
    expect(find.textContaining('已添加：小明'), findsOneWidget);
    await tester.tap(find.text('扫一扫'));
    await advanceUntil(tester, () => result != null);
    expect(result, carol.deviceId);
    expect(alice.friends.map((friend) => friend.nickname), containsAll(['小明', '小青']));
    semantics.dispose();
  });

  testWidgets('底栏消息角标：显示未读数，读屏读出条数', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: DragNavigationBar(selected: 0, onSelected: (_) {}, badges: const [0, 0, 3, 0])))));
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('消息，3 条未读')), findsOneWidget);
    semantics.dispose();
  });
}
