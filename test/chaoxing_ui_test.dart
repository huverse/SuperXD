import 'dart:async';
import 'dart:convert';


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_credential_pack.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_group_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_page.dart';
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
}

// 签到弹层里有循环加载动画，pumpAndSettle 等不到静止；入场动画走完再点，否则按钮还在屏幕外。
Future<void> openSignSheet(WidgetTester tester, {String button = '去签到'}) async {
  await tester.tap(find.widgetWithText(FilledButton, button));
  await tester.pump();
  // 详情到位主按钮才出现；入场动画走完再点，否则按钮还在屏幕外。
  await waitUntil(tester, () => find.widgetWithText(FilledButton, '签到').evaluate().isNotEmpty);
  await tester.pump(const Duration(milliseconds: 400));
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
    chaoxingHub: hub,
    chaoxing: ChaoxingAccounts(
      store: store,
      vault: MemoryChaoxingVault(),
      transport: (cookies) => ChaoxingHttp(client: fake.client(), cookies: cookies),
    ),
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
    await tester.enterText(find.widgetWithText(TextField, '签到码'), '1234');
    await tester.pump();
    await tapSign(tester);
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
    await tester.enterText(find.widgetWithText(TextField, '签到码'), '9999');
    await tester.pump();
    await tapSign(tester);
    await waitUntil(tester, () => find.text('签到码不对，核对后再试').evaluate().isNotEmpty);
    expect(fake.signQuery, isNull);
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

    await openSignSheet(tester, button: '去签到');
    await tester.tap(find.widgetWithText(OutlinedButton, '扫描签到二维码'));
    await tester.pump();
    await waitUntil(tester, () => find.widgetWithText(OutlinedButton, '重新扫描二维码').evaluate().isNotEmpty);
    await tapSign(tester);
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!['enc'], 'ENCV');
    expect(fake.signQuery!['activeId'], '501');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('主签到能跳到它发布的签退活动', (tester) async {
    usePhoneScreen(tester);
    fake.activeInfo = {'numberCount': 4, 'signOutId': 503, 'signOutPublishTimeStamp': 1760000000000};
    fake.activeInfos = {
      503: {'otherId': '5', 'nameOne': '签退', 'ifNeedVCode': 0},
    };
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester, button: '去签到');
    expect(find.text('这次签到还发布了签退活动'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '去签退'));
    await waitUntil(tester, () => find.textContaining('· 签退').evaluate().isNotEmpty);
    await tester.enterText(find.widgetWithText(TextField, '签到码'), '1234');
    await tester.pump();
    await tapSign(tester);
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
    await tester.enterText(find.widgetWithText(TextField, '签到码'), '1234');
    await tester.pump();
    await tapSign(tester);
    await waitUntil(tester, () => find.text('安全验证').evaluate().isNotEmpty);
    await waitUntil(tester, () => find.byType(Image).evaluate().length >= 2);
    await tester.drag(find.byType(Image).first, const Offset(60, 0));
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

  testWidgets('要人脸识别的签到会带上学习通里的人脸照片与 faceEnc', (tester) async {
    usePhoneScreen(tester);
    fake.activeInfo = {'numberCount': 4, 'openCheckFaceFlag': 1, 'signOutPublishTimeStamp': 4999};
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingPage(runtime: runtime)));
    await login(tester);

    await openSignSheet(tester, button: '去签到');
    expect(find.textContaining('人脸识别'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '签到码'), '1234');
    await tester.pump();
    await tapSign(tester);
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!['currentFaceId'], 'face-object-1');
    expect(fake.signQuery!['faceEnc'], 'FACE-ENC');
    expect(fake.signQuery!['ifCFP'], '0');
    expect(fake.faceQuery!['activeId'], '501');
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

    await tester.tap(find.byTooltip('从群聊里找签到'));
    await tester.pump();
    await waitUntil(tester, () => find.text('群里签到 · 签到码签到').evaluate().isNotEmpty);
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
    await waitUntil(tester, () => find.widgetWithText(TextField, '签到码').evaluate().isNotEmpty);
    await tester.enterText(find.widgetWithText(TextField, '签到码'), '1234');
    await tester.pump();
    await tapSign(tester);
    await waitUntil(tester, () => find.text('签到成功').evaluate().isNotEmpty);
    expect(fake.signQuery!['activeId'], '777');
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

    await tester.tap(find.byTooltip('从群聊里找签到'));
    await tester.pump();
    await waitUntil(tester, () => find.text('群里签到 · 签到码签到').evaluate().isNotEmpty);
    expect(find.textContaining('认不出类型的签到'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
