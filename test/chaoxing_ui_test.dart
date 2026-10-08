import 'dart:async';
import 'dart:convert';


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_captcha_dialog.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_code_cells.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_gesture_field.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_course_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_credential_pack.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_group_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_service.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_vault.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

import 'chaoxing_fake_hub.dart';
import 'chaoxing_fake_server.dart';
import 'toolbox_test_support.dart';

Future<void> waitUntil(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 200 && !done(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (!done()) {
    campusLog('[ChaoxingTest] visible=${find.byType(Text).evaluate().map((element) => (element.widget as Text).data).join(' | ')}');
  }
  expect(done(), isTrue);
}

// 默认测试画布是 800x600 的横向尺寸，竖排弹层会被挤出屏幕，这里按手机比例跑。
void usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<void> login(WidgetTester tester) async {
  await waitUntil(tester, () => find.text('学习通手机号').evaluate().isNotEmpty);
  await tester.enterText(find.byType(TextField).at(0), '13800138000');
  await tester.enterText(find.byType(TextField).at(1), 'myPassword123');
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, '登录'));
  await waitUntil(tester, () => find.text('同意并登录').evaluate().isNotEmpty);
  await tester.tap(find.text('同意并登录'));
  await tester.pump();
  await waitUntil(tester, () => find.widgetWithText(FilledButton, '去签到').evaluate().isNotEmpty);
  // 登录后有一轮后台刷新用户信息（跨几个库与网络回合），给它走完，免得测试结束时还挂着计时器。
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

// 签到弹层里有循环加载动画，pumpAndSettle 等不到静止；入场动画走完再点，否则按钮还在屏幕外。
Future<void> openSignSheet(WidgetTester tester, {String button = '去签到'}) async {
  await tester.tap(find.widgetWithText(FilledButton, button));
  await tester.pump();
  // 详情到位主按钮才出现；入场动画走完再点，否则按钮还在屏幕外。
  await waitUntil(tester, () => find.widgetWithText(FilledButton, '签到').evaluate().isNotEmpty);
  await tester.pump(const Duration(milliseconds: 400));
}

// 签到码是格子输入：先点格子聚焦（真正的输入框藏在格子底下），输满自动校验并提交；
// 详情里没给位数时退回普通输入框，直接往里输。
Future<void> enterCode(WidgetTester tester, String code) async {
  if (find.byType(ChaoxingCodeCells).evaluate().isNotEmpty) {
    await tester.tap(find.byType(ChaoxingCodeCells));
    await tester.pump();
    await tester.enterText(find.descendant(of: find.byType(ChaoxingCodeCells), matching: find.byType(TextField)), code);
  } else {
    await tester.enterText(find.widgetWithText(TextField, '签到码'), code);
  }
  await tester.pump();
}

Future<void> tapSign(WidgetTester tester) async {
  // 弹层入场还没滑完时量到的坐标在屏幕外，先让动画走完。
  await tester.pump(const Duration(milliseconds: 400));
  final button = find.widgetWithText(FilledButton, '签到');
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
}

// 首页底部的入口按钮在列表最下面，先滚到可见再点。
Future<void> tapEntry(WidgetTester tester, String label) async {
  final entry = find.widgetWithText(OutlinedButton, label);
  // 入口在 busy（登录后的收尾还没完）时是禁用的，直接点会静默落空，先等它可点。
  await waitUntil(tester, () => tester.widget<OutlinedButton>(entry).enabled);
  await tester.ensureVisible(entry);
  await tester.pump();
  await tester.tap(entry);
  await tester.pump();
}

Future<void> openGroups(WidgetTester tester) => tapEntry(tester, '群聊里的签到');

// 造一条环信漫游消息：Meta.field6 里是 MessageBody，它的 ext 里 key=attachment 的那项是签到附件。
List<int> _imVarint(int value) {
  final bytes = <int>[];
  var remaining = value;
  while (remaining > 0x7f) {
    bytes.add((remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  bytes.add(remaining);
  return bytes;
}

List<int> _imBytesField(int field, List<int> bytes) => [..._imVarint((field << 3) | 2), ..._imVarint(bytes.length), ...bytes];

List<int> _imAttachmentMessage({
  required int activeId,
  required int atype,
  required String atypeName,
  required String title,
}) {
  final attachment = jsonEncode({
    'attachmentType': 15,
    'att_chat_course': {
      'aid': activeId,
      'atype': atype,
      'atypeName': atypeName,
      'title': title,
      'courseInfo': {'classid': 88, 'courseid': 9001, 'coursename': '高等数学'},
    },
  });
  return _imBytesField(6, _imBytesField(5, [..._imBytesField(1, utf8.encode('attachment')), ..._imBytesField(6, utf8.encode(attachment))]));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ToolboxFixture fixture;
  late FakeChaoxing fake;
  late ChaoxingStore store;
  late ToolboxRuntime runtime;


  ToolboxRuntime buildRuntime({ToolboxQrScan? scanQrCode, ChaoxingPackHub? hub}) => ToolboxRuntime.testing(
    store: fixture.store,
    downloads: fixture.manager,
    parser: fixture.parser,
    scanQrCode: scanQrCode,
    services: {
      ChaoxingService.serviceId: ChaoxingService(
        accounts: ChaoxingAccounts(
          store: store,
          vault: MemoryChaoxingVault(),
          transport: (cookies) => ChaoxingHttp(client: fake.client(), cookies: cookies),
        ),
        hub: hub,
      ),
    },
  );

  setUp(() async {
    fixture = ToolboxFixture();
    await fixture.initialize();
    fake = await FakeChaoxing.create();
    fake.courses = [
      {
        'content': {
          'id': 88,
          'course': {
            'data': [
              {'id': 9001, 'name': '高等数学', 'teacherfactor': '张老师'},
            ],
          },
        },
      },
    ];
    fake.activities = [
      {'id': 501, 'type': 2, 'otherId': '5', 'nameOne': '签到', 'nameFour': '高等数学', 'startTime': 1760000000000, 'status': 1, 'userStatus': 0, 'ext': {'a': 1}},
    ];
    fake.activeInfo = {'numberCount': 4, 'signOutPublishTimeStamp': 4999};
    fake.preSignHtml = '<script>signstatus = 0;</script>';
    store = await ChaoxingStore.open(path.join(fixture.directory.path, 'chaoxing.db'));
    runtime = buildRuntime();
  });


  tearDown(() async {
    await store.close();
    await fixture.close();
  });

  testWidgets('百宝箱里能看到学习通签到入口', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: campusTheme(), home: ToolboxPage(runtime: runtime)),
    );
    await tester.pumpAndSettle();
    expect(find.text('学习通签到'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('未登录时先登录，登录后能完成签到码签到', (tester) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(
      MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)),
    );
    await waitUntil(tester, () => find.text('学习通手机号').evaluate().isNotEmpty);
    expect(find.text('密码'), findsOneWidget);
    await login(tester);
    expect(find.text('高等数学'), findsOneWidget);
    expect(find.textContaining('签到码签到'), findsOneWidget);

    await openSignSheet(tester);
    await enterCode(tester, '1234');
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!['signCode'], '1234');
    expect(fake.signQuery!['activeId'], '501');
    expect(fake.signQuery!['uid'], '7007');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('签到码不对时不提交，只提示', (tester) async {
    usePhoneScreen(tester);
    fake.checkSignCodeResult = 0;
    await tester.pumpWidget(
      MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)),
    );
    await login(tester);

    await openSignSheet(tester);
    await enterCode(tester, '9999');
    await waitUntil(tester, () => find.text('签到码不对，请重输').evaluate().isNotEmpty);
    expect(fake.signQuery, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('签到码签到可选绕过模式，不输码直接提交', (tester) async {
    usePhoneScreen(tester);
    // 普通模式下这个码必然校验不过；绕过模式既不该调预检，也不该带码。
    fake.checkSignCodeResult = 0;
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester);
    await waitUntil(tester, () => find.text('绕过').evaluate().isNotEmpty);
    await tester.tap(find.text('绕过'));
    await tester.pump();
    expect(find.text('该模式可能失效，请不要过度依赖此模式'), findsOneWidget);
    expect(find.byType(ChaoxingCodeCells), findsNothing);
    final checksBefore = fake.calls.where((call) => call.contains('checkSignCode')).length;
    await tester.tap(find.widgetWithText(FilledButton, '签到'));
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!.containsKey('signCode'), isFalse);
    expect(fake.calls.where((call) => call.contains('checkSignCode')).length, checksBefore);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('签到码格子输满自动校验并提交，不用点签到', (tester) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester);
    await enterCode(tester, '1234');
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!['signCode'], '1234');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手势签到画 3×3 图案，画完自动校验提交', (tester) async {
    usePhoneScreen(tester);
    fake.activities = [
      {'id': 501, 'type': 2, 'otherId': '3', 'nameOne': '签到', 'nameFour': '高等数学', 'startTime': 1760000000000, 'status': 1, 'userStatus': 0, 'ext': {'a': 1}},
    ];
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester);
    final field = find.byType(ChaoxingGestureField);
    await waitUntil(tester, () => field.evaluate().isNotEmpty);
    // 按九宫格的行列表出圆点中心，滑过 1、5、9 三个点。
    final topLeft = tester.getTopLeft(field);
    final width = tester.getSize(field).width;
    Offset dot(int row, int col) => topLeft + Offset((col + 0.5) * width / 3, (row + 0.5) * width / 3);
    final gesture = await tester.startGesture(dot(0, 0));
    // pan 手势要滑过系统触摸阈值才算开始，先在起点附近微移一下，否则起始点会丢。
    await gesture.moveBy(const Offset(20, 20));
    await gesture.moveTo(dot(1, 1));
    await gesture.moveTo(dot(2, 2));
    await gesture.up();
    await tester.pump();
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!['signCode'], '159');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('二维码签到：扫码后带 enc 提交', (tester) async {
    usePhoneScreen(tester);
    fake.activities = [
      {'id': 501, 'type': 2, 'otherId': '2', 'nameOne': '签到', 'nameFour': '高等数学', 'startTime': 1760000000000, 'status': 1, 'userStatus': 0, 'ext': {'a': 1}},
    ];
    fake.signDetail = {'isOver': 0, 'signCode': '501'};
    runtime = buildRuntime(scanQrCode: (context, hint, accept) async => 'SIGNIN:id=501&enc=ENCV-1.2.3');
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await tester.tap(find.widgetWithText(FilledButton, '去签到'));
    await tester.pump();
    await waitUntil(tester, () => find.widgetWithText(FilledButton, '扫码签到').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.widgetWithText(FilledButton, '扫码签到'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '扫码签到'));
    await tester.pump();
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!['enc'], 'ENCV');
    expect(fake.signQuery!['activeId'], '501');
    expect(fake.signQuery!['latitude'], '-1');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('主签到能跳到它发布的签退活动', (tester) async {
    usePhoneScreen(tester);
    fake.activeInfo = {'numberCount': 4, 'signOutId': 503, 'signOutPublishTimeStamp': 1760000000000};
    fake.activeInfos = {
      503: {'otherId': '5', 'nameOne': '签退', 'ifNeedVCode': 0, 'numberCount': 4},
    };
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester, button: '去签到');
    expect(find.text('这次签到还发布了签退活动'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '去签退'));
    await waitUntil(tester, () => find.text('签退 · ').evaluate().isNotEmpty);
    await enterCode(tester, '1234');
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!['activeId'], '503');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('要求安全验证时弹滑块，过了自动把签到重发一遍', (tester) async {
    usePhoneScreen(tester);
    fake.activeInfo = {'numberCount': 4, 'ifNeedVCode': 1, 'signOutPublishTimeStamp': 4999};
    fake.signResponses.addAll(['validate_enc-two', 'success']);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester, button: '去签到');
    await enterCode(tester, '1234');
    await waitUntil(tester, () => find.text('安全验证').evaluate().isNotEmpty);
    await waitUntil(tester, () => find.byType(Image).evaluate().length >= 2);
    await tester.drag(find.descendant(of: find.byType(ChaoxingCaptchaDialog), matching: find.byType(Image)).first, const Offset(60, 0));
    await tester.pump();
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!['validate'], 'captcha-validate');
    expect(fake.signQuery!['enc2'], 'enc-two');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('位置刚出界时收紧偏移自动重试一次', (tester) async {
    usePhoneScreen(tester);
    fake.activities = [
      {'id': 501, 'type': 2, 'otherId': '4', 'nameOne': '签到', 'nameFour': '高等数学', 'startTime': 1760000000000, 'status': 1, 'userStatus': 0, 'ext': {'a': 1}},
    ];
    fake.activeInfo = {
      'ifopenAddress': 1,
      'locationLatitude': 36.6,
      'locationLongitude': 117.0,
      'locationRange': 300,
      'signOutPublishTimeStamp': 4999,
    };
    fake.signResponses.addAll(['errorLocation_88.8', 'success']);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester, button: '去签到');
    // 没有收藏位置时直接是手输，坐标已按签到点预填。
    expect(find.widgetWithText(TextField, '纬度'), findsOneWidget);
    await tapSign(tester);
    // 位置签到成功后先弹「收藏这次的位置？」（附近无收藏时），点取消后再等主页面的成功提示。
    await waitUntil(tester, () => find.text('收藏这次的位置？').evaluate().isNotEmpty);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.calls.where((call) => call.contains('stuSignajax')).length, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('地图用不了时位置直接摊开经纬度，收藏的位置也还能选', (tester) async {
    usePhoneScreen(tester);
    fake.activities = [
      {'id': 501, 'type': 2, 'otherId': '4', 'nameOne': '签到', 'nameFour': '高等数学', 'startTime': 1760000000000, 'status': 1, 'userStatus': 0, 'ext': {'a': 1}},
    ];
    fake.activeInfo = {
      'ifopenAddress': 1,
      'locationLatitude': 36.6,
      'locationLongitude': 117.0,
      'locationRange': 300,
      'signOutPublishTimeStamp': 4999,
    };
    // 本机库走真实异步（后台 isolate），在 widget 测试的假时钟里必须用 runAsync 包住，否则永远等不回来。
    await tester.runAsync(
      () => store.putLocation(
        '知敬楼402',
        const ChaoxingLocation(latitude: 36.6, longitude: 117.0, address: '知敬楼402', system: ChaoxingCoordinateSystem.gcj02),
      ),
    );
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester, button: '去签到');
    // 没有地图 key（测试进程里也没有 arm 设备）时经纬度是默认路径，不是藏在「手动输入」后面。
    expect(find.text('这个安装包没有带地图，填经纬度或用收藏的位置'), findsOneWidget);
    expect(find.widgetWithText(TextField, '纬度'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '在地图上选点'), findsNothing);
    expect(find.widgetWithText(TextButton, '用收藏的位置'), findsOneWidget);

    // 换成收藏的位置照样能签。
    await tester.tap(find.widgetWithText(TextButton, '用收藏的位置'));
    await tester.pump();
    await tester.tap(find.widgetWithText(CampusGlassChip, '知敬楼402'));
    await tester.pump();
    await tapSign(tester);
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    // 用的就是收藏里的位置（500 米内已有收藏），不会再问要不要收藏。
    expect(find.text('收藏这次的位置？'), findsNothing);
    expect(fake.signQuery!['address'], '知敬楼402');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('账号菜单里有出示与扫码导入两个代签入口', (tester) async {
    usePhoneScreen(tester);
    runtime = buildRuntime(hub: ChaoxingPackHub(baseUrl: Uri.parse('http://relay.test'), client: FakePackHub().client()));
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
        home: ChaoxingPage(runtime: runtime),
      ),
    );
    await login(tester);

    await tester.tap(find.byTooltip('账号操作'));
    await tester.pump();
    await waitUntil(tester, () => find.text('出示我的代签码').evaluate().isNotEmpty);
    expect(find.text('扫别人的代签码'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('没配中转时不显示代签入口', (tester) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
        home: ChaoxingPage(runtime: runtime),
      ),
    );
    await login(tester);

    await tester.tap(find.byTooltip('账号操作'));
    await tester.pump();
    await waitUntil(tester, () => find.text('登录其他账号').evaluate().isNotEmpty);
    expect(find.text('出示我的代签码'), findsNothing);
    expect(find.text('扫别人的代签码'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('扫码导入：确认后把对方账号存进本机', (tester) async {
    usePhoneScreen(tester);
    await fake.addUser('13900139000', 'otherPassword1', name: '同学乙');
    final packs = FakePackHub();
    final hub = ChaoxingPackHub(baseUrl: Uri.parse('http://relay.test'), client: packs.client());
    // 对方出示的代签码：先封包投递，再拼出二维码文本。
    final sealed = await sealChaoxingCredentialPack(
      ChaoxingCredentialPack(
        phoneNumber: '13900139000',
        encryptedPassword: await chaoxingEncrypt('otherPassword1'),
        name: '同学乙',
        deviceCode: 'device-of-b',
      ),
    );
    final pickupId = await hub.submit(sealed.cipherText);
    final ticket = encodeChaoxingPackTicket(ChaoxingPackTicket(pickupId: pickupId, key: sealed.key));

    final controller = ChaoxingController(
      accounts: ChaoxingAccounts(
        store: store,
        vault: MemoryChaoxingVault(),
        transport: (cookies) => ChaoxingHttp(client: fake.client(), cookies: cookies),
      ),
      hub: hub,
    );
    // 登录要读本机库与网络桩，在假时钟里只能靠 runAsync 驱动。
    await tester.runAsync(() => controller.signIn('13800138000', 'myPassword123'));

    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: const Scaffold(body: Center(child: Text('宿主')))));
    unawaited(
      importChaoxingTicket(
        tester.element(find.text('宿主')),
        controller: controller,
        scan: (context, hint, accept) async => ticket,
      ),
    );
    await waitUntil(tester, () => find.text('导入代签账号').evaluate().isNotEmpty);
    await tester.tap(find.text('导入'));
    await tester.pump();
    await waitUntil(tester, () => find.text('已导入 同学乙').evaluate().isNotEmpty);
    expect(controller.accountList.map((item) => item.phoneNumber), contains('13900139000'));
    expect(controller.accountList.where((item) => item.isOtherUser), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('要人脸识别的位置签到会带上学习通里的人脸照片与 faceEnc', (tester) async {
    usePhoneScreen(tester);
    fake.activities = [
      {'id': 501, 'type': 2, 'otherId': '4', 'nameOne': '签到', 'nameFour': '高等数学', 'startTime': 1760000000000, 'status': 1, 'userStatus': 0},
    ];
    fake.activeInfo = {
      'openCheckFaceFlag': 1,
      'ifopenAddress': 1,
      'locationLatitude': 36.6,
      'locationLongitude': 117.0,
      'signOutPublishTimeStamp': 4999,
    };
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester, button: '去签到');
    expect(find.textContaining('人脸识别'), findsOneWidget);
    await tapSign(tester);
    // 开签前补给：本机没存人脸照片时先问，选重处理学习通存的默认照片（下载→随机裁剪旋转→重新上传换新 id）。
    await waitUntil(tester, () => find.text('重处理默认照片').evaluate().isNotEmpty);
    await tester.tap(find.text('重处理默认照片'));
    await tester.pump();
    // 位置签到成功后先弹「收藏这次的位置？」（附近无收藏时），点取消后再等主页面的成功提示。
    await waitUntil(tester, () => find.text('收藏这次的位置？').evaluate().isNotEmpty);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    // 用的是重处理上传后的新 objectId（fake 的云盘上传固定回 obj-1），不再是学习通里那张的原 objectId。
    expect(fake.signQuery!['currentFaceId'], 'obj-1');
    expect(fake.signQuery!['faceEnc'], 'FACE-ENC');
    expect(fake.signQuery!['ifCFP'], '0');
    expect(fake.faceQuery!['activeId'], '501');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('checkFace_ 是校验没完成：带着 enc2 自动重发，不给人脸照片记失败', (tester) async {
    usePhoneScreen(tester);
    fake.activities = [
      {'id': 501, 'type': 2, 'otherId': '4', 'nameOne': '签到', 'nameFour': '高等数学', 'startTime': 1760000000000, 'status': 1, 'userStatus': 0},
    ];
    fake.activeInfo = {
      'openCheckFaceFlag': 1,
      'ifopenAddress': 1,
      'locationLatitude': 36.6,
      'locationLongitude': 117.0,
      'signOutPublishTimeStamp': 4999,
    };
    fake.signResponses.addAll(['checkFace_enc-next', 'success']);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester, button: '去签到');
    await tapSign(tester);
    await waitUntil(tester, () => find.text('重处理默认照片').evaluate().isNotEmpty);
    await tester.tap(find.text('重处理默认照片'));
    await tester.pump();
    // 位置签到成功后先弹「收藏这次的位置？」（附近无收藏时），点取消后再等主页面的成功提示。
    await waitUntil(tester, () => find.text('收藏这次的位置？').evaluate().isNotEmpty);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    // 第二次提交把 checkFace_ 的后缀作为 enc2 续传上去。
    expect(fake.signQuery!['enc2'], 'enc-next');
    // 校验没完成不算人脸未通过：照片不该被标失败（失败标记只在 [face] 时打）。
    final faces = await tester.runAsync(() => store.faceImages('13800138000')) ?? [];
    expect(faces.where((face) => face.failedBefore), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('群聊里的签到能从群聊页直接签', (tester) async {
    usePhoneScreen(tester);
    fake.imGroups.addAll([
      {'id': 'g1', 'name': '高等数学群'},
    ]);
    fake.imMessages.addAll([
      _imAttachmentMessage(activeId: 777, atype: 2, atypeName: '密码签到', title: '群里签到'),
    ]);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openGroups(tester);
    await waitUntil(tester, () => find.text('群里签到 · ').evaluate().isNotEmpty);
    // 等页面转场滑完再点，转场中途量到的坐标还在屏幕外。
    await tester.pump(const Duration(milliseconds: 400));
    // 群聊页是推上去的，底下主页面也有“去签到”，按页面类型限定一下。
    await tester.tap(
      find.descendant(
        of: find.byType(ChaoxingGroupPage),
        matching: find.widgetWithText(FilledButton, '去签到'),
      ),
    );
    await tester.pump();
    await waitUntil(tester, () => find.byType(ChaoxingCodeCells).evaluate().isNotEmpty);
    await enterCode(tester, '1234');
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!['activeId'], '777');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('群名是空的用描述里的课程名，群聊活动按发起时间排序', (tester) async {
    usePhoneScreen(tester);
    // 群描述是 JSON 信封，课程名在 courseInfo.coursename；纯文本描述解析不出课程名、群名又为空时整群跳过。
    fake.imGroups.addAll([
      {'id': 'g1', 'name': '', 'description': jsonEncode({'courseInfo': {'coursename': '高等数学（周二三四节）'}})},
      {'id': 'g2', 'name': '', 'description': '不是 JSON 的纯文本'},
    ]);
    // 附件里没带课程名时，卡片说明行落到群名（这里是描述）上。
    List<int> messageOf(int activeId, String title) => _imBytesField(
      6,
      _imBytesField(5, [
        ..._imBytesField(1, utf8.encode('attachment')),
        ..._imBytesField(
          6,
          utf8.encode(
            jsonEncode({
              'attachmentType': 15,
              'att_chat_course': {'aid': activeId, 'atype': 2, 'atypeName': '密码签到', 'title': title, 'courseInfo': {'classid': 88, 'courseid': 9001}},
            }),
          ),
        ),
      ]),
    );
    fake.imMessages.addAll([messageOf(888, '较早的签到'), messageOf(777, '刚发起的签到')]);
    fake.imTimestamps.addAll([1700000000000, 1800000000000]);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openGroups(tester);
    await waitUntil(tester, () => find.text('较早的签到 · ').evaluate().isNotEmpty);
    expect(find.text('高等数学（周二三四节）'), findsWidgets);
    // 发起晚的排在上面。
    final recent = tester.getTopLeft(find.text('刚发起的签到 · '));
    final older = tester.getTopLeft(find.text('较早的签到 · '));
    expect(recent.dy < older.dy, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('群聊里单条活动详情读不到时只跳过那一条', (tester) async {
    usePhoneScreen(tester);
    fake.imGroups.addAll([
      {'id': 'g1', 'name': '高等数学群'},
    ]);
    fake.imMessages.addAll([
      // 类型名认不出来，必须去详情里问；这条详情读不到，应只跳过它，不能让整页失败。
      _imAttachmentMessage(activeId: 777, atype: 2, atypeName: '签到', title: '认不出类型的签到'),
      _imAttachmentMessage(activeId: 888, atype: 2, atypeName: '密码签到', title: '群里签到'),
    ]);
    fake.failingActiveInfoIds.add(777);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openGroups(tester);
    await waitUntil(tester, () => find.text('群里签到 · ').evaluate().isNotEmpty);
    expect(find.textContaining('认不出类型的签到'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('多个账号时可以一次给本人与代签账号连签', (tester) async {
    usePhoneScreen(tester);
    await fake.addUser('13900139000', 'otherPassword1', name: '同学乙');
    final accounts = (await runtime.service<ChaoxingService>(ChaoxingService.serviceId)).accounts;
    await tester.runAsync(
      () async => accounts.importOther(
        ChaoxingCredentialPack(
          phoneNumber: '13900139000',
          encryptedPassword: await chaoxingEncrypt('otherPassword1'),
          name: '同学乙',
          deviceCode: 'device-of-b',
        ),
      ),
    );
    await tester.runAsync(() => accounts.signIn(phoneNumber: '13800138000', password: 'myPassword123'));
    final callsBefore = fake.calls.length;
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    // 本机已有账号但没同意过当前版本的说明：先重新征得同意才联网。
    await waitUntil(tester, () => find.text('学习通签到的说明更新了').evaluate().isNotEmpty);
    expect(fake.calls.skip(callsBefore), isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, '同意'));
    await tester.pump();
    // 本人账号排在前面，打开就是本人；代签账号在签到对象里，默认不勾。
    await waitUntil(tester, () => find.widgetWithText(FilledButton, '去签到').evaluate().isNotEmpty);
    await openSignSheet(tester);
    expect(find.text('签到对象'), findsOneWidget);
    expect(find.text('同学乙'), findsOneWidget);
    final second = find.byType(Checkbox).last;
    await tester.ensureVisible(second);
    await tester.pump();
    await tester.tap(second);
    await tester.pump();
    // 签到码输满即自动连签两人，不用点签到。
    await enterCode(tester, '1234');
    await waitUntil(tester, () => find.text('已为 2 人签到').evaluate().isNotEmpty);
    // 最后签的是代签账号，带的是对方的设备码。
    expect(fake.signQuery!['deviceCode'], 'device-of-b');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('往期签到照样能签，签到页提示可能记为迟到', (tester) async {
    usePhoneScreen(tester);
    fake.activities = [
      {'id': 601, 'type': 2, 'otherId': '5', 'nameOne': '上周的签到', 'startTime': 1760000000000, 'endTime': 1760000600000, 'status': 2, 'userStatus': 0},
    ];
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await waitUntil(tester, () => find.text('学习通手机号').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField).at(0), '13800138000');
    await tester.enterText(find.byType(TextField).at(1), 'myPassword123');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await waitUntil(tester, () => find.text('同意并登录').evaluate().isNotEmpty);
    await tester.tap(find.text('同意并登录'));
    await tester.pump();
    await waitUntil(tester, () => find.text('往期签到（1）').evaluate().isNotEmpty);

    await tapEntry(tester, '往期签到（1）');
    await waitUntil(tester, () => find.text('往期签到').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await openSignSheet(tester);
    expect(find.textContaining('可能会记为迟到'), findsOneWidget);
    await enterCode(tester, '1234');
    await waitUntil(tester, () => find.text('签到成功，不过已经迟到').evaluate().isNotEmpty);
    expect(fake.signQuery!['activeId'], '601');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('打开签到页就发现已签到，三选里能强制签到', (tester) async {
    usePhoneScreen(tester);
    fake.preSignHtml = '<script>signstatus = 1;</script>';
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester);
    // 打开即检查：勾选的人全被拦时弹三选，本人原地标出原因并取消勾选。
    await waitUntil(tester, () => find.text('我认为是 BUG，强制签到').evaluate().isNotEmpty);
    expect(find.text('这场签到检查没过'), findsOneWidget);
    expect(find.text('这场签到已经完成了'), findsOneWidget);
    expect(fake.signQuery, isNull);
    // 没填签到码就选强制：先被要求补输入（对话框关闭、本人恢复勾选）。
    await tester.tap(find.text('我认为是 BUG，强制签到'));
    await tester.pump();
    await waitUntil(tester, () => find.text('我认为是 BUG，强制签到').evaluate().isEmpty);
    await waitUntil(tester, () => find.text('请填写签到码').evaluate().isNotEmpty);
    // 填码后普通提交仍会被拦，再走单人的强制签到。
    await enterCode(tester, '1234');
    await waitUntil(tester, () => find.widgetWithText(OutlinedButton, '强制签到').evaluate().isNotEmpty);
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '强制签到'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, '强制签到'));
    await tester.pump();
    await waitUntil(tester, () => find.widgetWithText(FilledButton, '强制签到').evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(FilledButton, '强制签到'));
    await tester.pump();
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!['signCode'], '1234');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('按课程查看：同名课合并，进行中与已结束分开', (tester) async {
    usePhoneScreen(tester);
    // 同一门课两个班：假服务对两个班给回同一批活动，首页按活动号去重，不能出现重复条目。
    fake.courses = [
      for (final classId in [88, 89])
        {
          'content': {
            'id': classId,
            'course': {
              'data': [
                {'id': 9001, 'name': '高等数学', 'teacherfactor': '张老师'},
              ],
            },
          },
        },
    ];
    fake.activities = [
      {'id': 501, 'type': 2, 'otherId': '5', 'nameOne': '今天的签到', 'startTime': 1760000000000, 'status': 1, 'userStatus': 0},
      {'id': 502, 'type': 2, 'otherId': '5', 'nameOne': '上周的签到', 'startTime': 1759000000000, 'status': 2, 'userStatus': 0},
    ];
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    expect(find.text('今天的签到 · '), findsOneWidget);
    await tapEntry(tester, '按课程查看（1）');
    await waitUntil(tester, () => find.text('搜索课程、老师或学校').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('高等数学'), findsWidgets);
    // 说明行由 DotSeparatedText 按项拆开渲染，按拆分后的项断言。
    expect(find.text('张老师 · '), findsOneWidget);
    expect(find.text('2 个班'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ChaoxingCoursePage), matching: find.text('高等数学')));
    await tester.pump();
    await waitUntil(tester, () => find.text('进行中（1）').evaluate().isNotEmpty);
    expect(find.text('已结束（1）'), findsOneWidget);
    expect(find.text('这门课有 2 个班，签到已合并显示'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('按学习通课表推断正在上的课里刚发起的签到', (tester) async {
    usePhoneScreen(tester);
    final now = DateTime.now().toUtc();
    final local = campusInstant(now);
    fake.lessons = {
      'curriculum': {'lessonTimeConfigArray': ['00:00-23:59'], 'firstWeekDate': now.millisecondsSinceEpoch},
      'lessonArray': [
        {'name': '高等数学（一）', 'dayOfWeek': local.weekday, 'beginNumber': 1, 'length': 1, 'weeks': '1', 'classId': 0, 'courseId': 0},
      ],
    };
    fake.activities = [
      {'id': 501, 'type': 2, 'otherId': '5', 'nameOne': '刚发起的签到', 'startTime': now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch, 'status': 1, 'userStatus': 0},
    ];
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);
    // 推断是主列表之后的一步异步（拉课表再匹配），登录回来不保证已经算完，显式等它出现。
    await waitUntil(tester, () => find.text('可能正在签到（按学习通课表）').evaluate().isNotEmpty);
    expect(find.text('可能正在签到（按学习通课表）'), findsOneWidget);
    // 推断里已经列出的，不在「进行中」里重复。
    expect(find.text('刚发起的签到 · '), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('课表班级不在课程列表时，推断直查活动列表也能翻出来', (tester) async {
    usePhoneScreen(tester);
    final now = DateTime.now().toUtc();
    final local = campusInstant(now);
    // 课表自带的班级号不在课程列表里（隐藏班）：推断对这个班直查一次活动列表（对齐参考项目）。
    fake.lessons = {
      'curriculum': {'lessonTimeConfigArray': ['00:00-23:59'], 'firstWeekDate': now.millisecondsSinceEpoch},
      'lessonArray': [
        {'name': '体育', 'dayOfWeek': local.weekday, 'beginNumber': 1, 'length': 1, 'weeks': '1', 'classId': 999, 'courseId': 8001},
      ],
    };
    fake.activities = [
      {'id': 701, 'type': 2, 'otherId': '5', 'nameOne': '隐藏班刚发起的签到', 'startTime': now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch, 'status': 1, 'userStatus': 0},
    ];
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);
    await waitUntil(tester, () => find.text('可能正在签到（按学习通课表）').evaluate().isNotEmpty);
    expect(find.text('隐藏班刚发起的签到 · '), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('本机已有账号时不同意新版说明就退出工具，不联网', (tester) async {
    usePhoneScreen(tester);
    await tester.runAsync(() async => (await runtime.service<ChaoxingService>(ChaoxingService.serviceId)).accounts
        .signIn(phoneNumber: '13800138000', password: 'myPassword123'));
    final callsBefore = fake.calls.length;
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ChaoxingPage(runtime: runtime))),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await waitUntil(tester, () => find.text('学习通签到的说明更新了').evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pump();
    await waitUntil(tester, () => find.byType(ChaoxingPage).evaluate().isEmpty);
    expect(fake.calls.skip(callsBefore), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('人脸照片保存到下载目录走一次性导出，文件名带净化的 objectId 且按名幂等', (tester) async {
    final publisher = FakePublisher();
    final controller = ChaoxingController(
      accounts: ChaoxingAccounts(
        store: store,
        vault: MemoryChaoxingVault(),
        transport: (cookies) => ChaoxingHttp(client: fake.client(), cookies: cookies),
      ),
      filePublisher: () => publisher,
    );
    await tester.runAsync(() => controller.signIn('13800138000', 'myPassword123'));

    // objectId 是学习通云盘给的外部输入，路径分隔符等不安全字符不得进入导出文件名。
    final uri = await tester.runAsync(() => controller.faces.saveFaceImage('face/obj:1'));
    expect(Uri.decodeComponent(uri.toString()), 'content://media/external/人脸照片-faceobj1.jpg');
    expect(publisher.externalFilename, '人脸照片-faceobj1.jpg');

    // 同一张照片重复保存：原生按文件名幂等，直接拿回同一个地址。
    final again = await tester.runAsync(() => controller.faces.saveFaceImage('face/obj:1'));
    expect(again.toString(), uri.toString());
    await tester.pumpWidget(const SizedBox());
  });
}
