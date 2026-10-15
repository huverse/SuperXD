import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_account_sheet.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_code_cells.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_gesture_field.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_qrcode.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_signer.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_tag_sheet.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_vault.dart';

import 'chaoxing_fake_server.dart';

// 2026-10-08 审查整改的回归：删账号与后台刷新的竞态、会话关闭、切账号代次、自动重登的错误口径、
// 手势与签到码输入的重复提交。

// 记录是否被关闭的 HTTP 客户端：会话关没关只能从这里看出来。
class _TrackedClient extends http.BaseClient {
  _TrackedClient(this._inner);
  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request);

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}

// 第一次课程列表请求卡在闸门上，放行时按断网失败（模拟切账号前还没回来的旧请求）。
class _GatedClient extends http.BaseClient {
  _GatedClient(this._inner, this.gate);
  final http.Client _inner;
  final Completer<void> gate;
  static bool used = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!used && request.url.host == 'mooc1-api.chaoxing.com') {
      used = true;
      await gate.future;
      throw const SocketException('offline');
    }
    return _inner.send(request);
  }
}

void main() {
  late Directory directory;
  late ChaoxingStore store;
  late FakeChaoxing fake;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final root = await Directory(path.join(Directory.current.path, 'build', 'chaoxing_tests')).create(recursive: true);
    directory = await root.createTemp('regression_');
    store = await ChaoxingStore.open(path.join(directory.path, 'chaoxing.db'));
    fake = await FakeChaoxing.create();
    _GatedClient.used = false;
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  ChaoxingAccounts accountsWith(ChaoxingVault vault) => ChaoxingAccounts(
    store: store,
    vault: vault,
    transport: (cookies) => ChaoxingHttp(client: fake.client(), cookies: cookies),
  );

  test('位置签到默认选中的位置：这门课上次签到用的优先，没有就用上次签到用的，都没有为空；收藏不算', () async {
    final controller = ChaoxingController(accounts: accountsWith(MemoryChaoxingVault()));
    ChaoxingActivity activityIn(int classId) => ChaoxingActivity(
      activeId: classId,
      courseId: classId,
      classId: classId,
      title: '位置签到',
      subtitle: '课程',
      signType: ChaoxingSignType.location,
      startTime: null,
      status: 1,
      userStatus: 0,
      ext: '',
    );
    await controller.saveLocation('知敬楼', const ChaoxingLocation(latitude: 36.1, longitude: 117.1, address: '知敬楼'));
    expect(await controller.signedLocation(activityIn(1)), isNull);
    await controller.rememberSignedLocation(activityIn(1), const ChaoxingLocation(latitude: 36.65, longitude: 117.03, address: '博学楼', system: ChaoxingCoordinateSystem.gcj02));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await controller.rememberSignedLocation(activityIn(2), const ChaoxingLocation(latitude: 36.7, longitude: 117.1, address: '图书馆', system: ChaoxingCoordinateSystem.gcj02));
    final own = await controller.signedLocation(activityIn(1));
    expect([own?.latitude, own?.longitude, own?.system], [36.65, 117.03, ChaoxingCoordinateSystem.gcj02]);
    expect((await controller.signedLocation(activityIn(3)))?.address, '图书馆');
    // 只是默认位置，不进收藏。
    expect(controller.locations.map((saved) => saved.label), ['知敬楼']);
  });

  test('preSign 回 403 时重登一次再重发；重发还是 403 就按登录过期报（参考项目 1.19.2「访问被拒绝」）', () async {
    final accounts = accountsWith(MemoryChaoxingVault());
    await accounts.signIn(phoneNumber: '13800138000', password: 'myPassword123');
    final client = (await accounts.clientFor('13800138000'))!;
    const activity = ChaoxingActivity(
      activeId: 501,
      courseId: 9001,
      classId: 88,
      title: '签到',
      subtitle: '高等数学',
      signType: ChaoxingSignType.password,
      startTime: null,
      status: 1,
      userStatus: 0,
      ext: '{}',
    );
    int logins() => fake.calls.where((call) => call.endsWith('/fanyalogin')).length;
    fake.preSignHtml = '<script>signstatus = 0;</script>';
    final before = logins();
    fake.forbiddenPreSigns = 1;
    expect(await accounts.run(client, () => chaoxingPreSign(client, activity)), ChaoxingPreSignStatus.readyToSign);
    expect(logins(), before + 1);
    fake.forbiddenPreSigns = 2;
    await expectLater(
      accounts.run(client, () => chaoxingPreSign(client, activity)),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.sessionExpired)),
    );
    client.close();
  });

  List<Map<String, Object?>> mathCourse() => [
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

  test('课表推断轮询：正有课却还没推断到签到时隔一会儿重查这节课，老师后发起的签到也会冒出来（参考项目 1.19.2）', () async {
    final now = DateTime.now().toUtc();
    fake.courses = mathCourse();
    fake.lessons = {
      'curriculum': {'lessonTimeConfigArray': ['00:00-23:59'], 'firstWeekDate': now.millisecondsSinceEpoch},
      'lessonArray': [
        {'name': '高等数学（一）', 'dayOfWeek': campusInstant(now).weekday, 'beginNumber': 1, 'length': 1, 'weeks': '1', 'classId': 0, 'courseId': 0},
      ],
    };
    final controller = ChaoxingController(accounts: accountsWith(MemoryChaoxingVault()), lessonPollInterval: const Duration(milliseconds: 20));
    await controller.signIn('13800138000', 'myPassword123');
    expect(controller.lessonActivities, isEmpty);
    fake.activities = [
      {'id': 501, 'type': 2, 'otherId': '5', 'nameOne': '后发起的签到', 'startTime': DateTime.now().toUtc().millisecondsSinceEpoch, 'status': 1, 'userStatus': 0},
    ];
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (controller.lessonActivities.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(controller.lessonActivities.map((activity) => activity.activeId), [501]);
    // 退出会先等登录后的后台刷新落定，免得测试收尾关库时它还在写。
    await controller.signOut();
    controller.dispose();
  });

  test('扫课堂签到二维码：按详情组出活动，课程号缺了按班级到课程列表里找，不在列表里的课也能签（参考项目 1.19.2）', () async {
    fake.courses = mathCourse();
    final controller = ChaoxingController(accounts: accountsWith(MemoryChaoxingVault()));
    await controller.signIn('13800138000', 'myPassword123');
    fake.activeInfos[777] = {'otherId': '2', 'nameOne': '二维码签到', 'clazzid': 88, 'courseId': 0};
    final scanned = await controller.scannedActivity(chaoxingParseQrCode('SIGNIN:aid=777&source=15&Code=777&enc=ABC')!);
    expect([scanned.activeId, scanned.classId, scanned.courseId, scanned.subtitle, scanned.signType], [777, 88, 9001, '高等数学', ChaoxingSignType.qrCode]);
    fake.activeInfos[778] = {'otherId': '4', 'nameOne': '位置签到', 'clazzid': 55, 'courseId': 5005};
    final outside = await controller.scannedActivity(const ChaoxingQrCode(enc: 'ABC', activeId: 778));
    expect([outside.classId, outside.courseId, outside.subtitle, outside.ongoing], [55, 5005, '课堂签到', isTrue]);
    await expectLater(controller.scannedActivity(const ChaoxingQrCode(enc: 'ABC')), throwsA(isA<ChaoxingFailure>()));
    await controller.signOut();
    controller.dispose();
  });

  test('后台刷新跨过删除时，不把已删账号的会话写回安全存储', () async {
    final vault = MemoryChaoxingVault();
    final accounts = accountsWith(vault);
    await accounts.signIn(phoneNumber: '13800138000', password: 'myPassword123');
    final client = (await accounts.clientFor('13800138000'))!;
    await accounts.forget('13800138000');
    await accounts.refreshAccount(client);
    expect(vault.cookies, isEmpty);
    expect(vault.passwords, isEmpty);
    client.close();
  });

  test('自动重登遇到断网时照实报网络错误，不说成登录已过期', () async {
    final accounts = ChaoxingAccounts(
      store: store,
      vault: MemoryChaoxingVault(),
      transport: (cookies) => ChaoxingHttp(cookies: cookies),
    );
    final client = ChaoxingClient(
      http: ChaoxingHttp(client: MockClient((_) async => throw const SocketException('offline'))),
      phoneNumber: '13800138000',
      encryptedPassword: 'cipher',
      deviceCode: 'device',
    );
    final failure = await accounts
        .run<void>(client, () async => throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, chaoxingSessionExpiredMessage))
        .then<ChaoxingFailure?>((_) => null, onError: (Object error) => error as ChaoxingFailure);
    expect(failure!.code, ChaoxingFailureCode.network);
    expect(failure.message, isNot(chaoxingSessionExpiredMessage));
  });

  testWidgets('账号管理：登录已失效的标出来、一点就重新登录；能新建标签、给账号设标签并显示在行里', (tester) async {
    final accounts = accountsWith(MemoryChaoxingVault());
    final controller = ChaoxingController(accounts: accounts);
    Future<void> waitFor(String what, Future<bool> Function() done) async {
      for (var round = 0; round < 250; round++) {
        // 读写库与假服务都是真异步：先让真实时间走一小段，再看结果。
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        if (await tester.runAsync(done) == true) {
          await tester.pumpAndSettle();
          return;
        }
        await tester.pump();
      }
      fail('等待超时：$what');
    }

    await tester.runAsync(() async {
      await accounts.signIn(phoneNumber: '13800138000', password: 'myPassword123');
      await store.setSessionExpired('13800138000', expired: true);
      await controller.reloadAccounts();
    });
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: const Scaffold(body: Center(child: Text('宿主')))));
    unawaited(showChaoxingAccountSheet(tester.element(find.text('宿主')), controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('登录已失效'), findsOneWidget);

    // 一点警示图标就重新输密码，修好后标记与图标一起消失。
    await tester.tap(find.byTooltip('登录已失效，重新登录'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'myPassword123');
    await tester.tap(find.text('登录'));
    await waitFor('修复后列表刷新', () async => !controller.accountList.single.sessionExpired);
    expect(find.byTooltip('登录已失效，重新登录'), findsNothing);
    expect(find.text('登录已失效'), findsNothing);

    // 新建一个蓝色的「室友」标签。
    await tester.tap(find.byTooltip('标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '室友');
    await tester.tap(find.byTooltip('蓝'));
    await tester.tap(find.text('保存'));
    await waitFor('新建标签写库', () async => (await store.tags()).length == 1);
    final tag = (await tester.runAsync(store.tags))!.single;
    expect((tag.name, tag.colorIndex), ('室友', 4));
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();

    // 给账号设上这个标签，行里显示出来。
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.tap(find.text('保存'));
    await waitFor('账号标签写库', () async => (await store.accountTags())['13800138000']?.contains(tag.id) == true);
    expect(find.descendant(of: find.byType(ChaoxingTagLabel), matching: find.text('室友')), findsOneWidget);
    controller.dispose();
  });

  test('自动重登被拒记下「登录已失效」，签到对象一打开就要修复；重登成功或修复后清掉', () async {
    final vault = MemoryChaoxingVault();
    final accounts = accountsWith(vault);
    await accounts.signIn(phoneNumber: '13800138000', password: 'myPassword123');
    final client = (await accounts.clientFor('13800138000'))!;
    Future<void> expire() async => throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, chaoxingSessionExpiredMessage);
    // 对方改了密码：自动重登被拒，记进本机库。
    final original = fake.users['13800138000']!;
    fake.users['13800138000'] = (phoneCipher: original.phoneCipher, passwordCipher: 'changed', name: original.name);
    await expectLater(accounts.run<void>(client, expire), throwsA(isA<ChaoxingFailure>()));
    final expired = (await accounts.record('13800138000'))!;
    expect(expired.sessionExpired, isTrue);
    expect(expired.sessionLabel, '登录已失效');
    final controller = ChaoxingController(accounts: accounts)..accountList = [expired];
    expect(controller.signTargets().single.needsRepair, isTrue);
    controller.dispose();

    // 密码改回来、自动重登成功：标记清掉。
    fake.users['13800138000'] = original;
    var attempts = 0;
    await accounts.run<void>(client, () async {
      if (attempts++ == 0) await expire();
    });
    expect((await accounts.record('13800138000'))!.sessionExpired, isFalse);

    // 重输密码修复同样清掉。
    await store.setSessionExpired('13800138000', expired: true);
    await accounts.repair(client, 'myPassword123');
    expect((await accounts.record('13800138000'))!.sessionExpired, isFalse);
    client.close();
  });

  test('删除当前账号时关掉它的会话', () async {
    final vault = MemoryChaoxingVault();
    await accountsWith(vault).signIn(phoneNumber: '13800138000', password: 'myPassword123');
    final opened = <_TrackedClient>[];
    final controller = ChaoxingController(
      accounts: ChaoxingAccounts(
        store: store,
        vault: vault,
        transport: (cookies) {
          final tracked = _TrackedClient(fake.client());
          opened.add(tracked);
          return ChaoxingHttp(client: tracked, cookies: cookies);
        },
      ),
    );
    await controller.initialize();
    final session = opened.last;
    expect(session.closed, isFalse);
    await controller.removeAccount(controller.current!);
    expect(session.closed, isTrue);
    expect(controller.status, ChaoxingStatus.signedOut);
    controller.dispose();
  });

  test('首屏还在加载时切换账号，旧账号的失败不落到新账号上', () async {
    await fake.addUser('13900139000', 'otherPassword1', name: '同学乙');
    final vault = MemoryChaoxingVault();
    await accountsWith(vault).signIn(phoneNumber: '13800138000', password: 'myPassword123');
    await accountsWith(vault).signIn(phoneNumber: '13900139000', password: 'otherPassword1');
    final gate = Completer<void>();
    final controller = ChaoxingController(
      accounts: ChaoxingAccounts(
        store: store,
        vault: vault,
        transport: (cookies) => ChaoxingHttp(client: _GatedClient(fake.client(), gate), cookies: cookies),
      ),
    );
    final loading = controller.initialize();
    for (var attempt = 0; attempt < 2000 && !_GatedClient.used; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (!_GatedClient.used) fail('等待超时：首屏课程列表请求卡在闸门上');
    final first = controller.current!;
    final other = controller.accountList.firstWhere((record) => record.phoneNumber != first.phoneNumber);
    await controller.select(other);
    gate.complete();
    await loading;
    expect(controller.current!.phoneNumber, other.phoneNumber);
    expect(controller.error, isNull);
    expect(controller.loadingActivities, isFalse);
    controller.dispose();
  });

  test('打开库时裁掉过期的学习通课表缓存', () async {
    await store.putLessonCache('13800138000', '{}');
    await store.putLessonCache('13900139000', '{}');
    await store.close();
    final database = await databaseFactoryFfi.openDatabase(path.join(directory.path, 'chaoxing.db'));
    final expired = DateTime.now().toUtc().subtract(ChaoxingStore.lessonCacheLifetime + const Duration(minutes: 1));
    await database.update('lesson_cache', {'fetched_at': expired.millisecondsSinceEpoch}, where: 'phone_number = ?', whereArgs: ['13800138000']);
    await database.close();
    store = await ChaoxingStore.open(path.join(directory.path, 'chaoxing.db'));
    expect(await store.lessonCache('13800138000'), isNull);
    expect(await store.lessonCache('13900139000'), isNotNull);
  });

  testWidgets('键盘弹出时弹层面板整块浮到键盘上方', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 800), viewInsets: EdgeInsets.only(bottom: 300), padding: EdgeInsets.only(bottom: 24)),
          child: const Align(alignment: Alignment.bottomCenter, child: CampusSheetPanel(child: SizedBox(height: 100, width: 300))),
        ),
      ),
    );
    final bottom = tester.getBottomLeft(find.byType(SizedBox).last).dy;
    expect(bottom, lessThanOrEqualTo(800 - 300));
  });

  testWidgets('账号管理：主账号置顶不可拖，其余自己的与代签账号一起拖动排序并写回；只有自己的账号能设为主账号', (tester) async {
    ChaoxingAccountRecord record(String phone, {required bool other, required int minutes}) => ChaoxingAccountRecord(
      phoneNumber: phone,
      uid: 1,
      puid: 2,
      fid: 3,
      name: '同学$phone',
      schoolName: '示例大学',
      deviceCode: 'device-$phone',
      isOtherUser: other,
      createdAt: DateTime.utc(2026, 10, 8).add(Duration(minutes: minutes)),
    );
    final controller = ChaoxingController(accounts: accountsWith(MemoryChaoxingVault()));
    await tester.runAsync(() async {
      await store.putAccount(record('138', other: false, minutes: 0));
      await store.putAccount(record('139', other: true, minutes: 2));
      await store.putAccount(record('137', other: true, minutes: 1));
      await store.putAccount(record('136', other: false, minutes: 3));
      controller.accountList = await controller.accounts.list();
    });
    // 没设过主账号时取最早登录的自己账号（138），其余按登录时间新的在前。
    expect(controller.accountList.map((item) => item.phoneNumber), ['138', '136', '139', '137']);
    expect(controller.mainPhoneNumber, '138');
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: const Scaffold(body: Center(child: Text('宿主')))));
    unawaited(showChaoxingAccountSheet(tester.element(find.text('宿主')), controller: controller));
    await tester.pumpAndSettle();
    // 只标例外：主账号写「主账号」，代签账号写「代签账号」，其余自己的账号不写归属。
    expect(find.text('主账号'), findsOneWidget);
    expect(find.text('代签账号'), findsNWidgets(2));
    expect(find.textContaining('本人'), findsNothing);
    expect(find.text('其他账号 · 按住右侧把手拖动排序'), findsOneWidget);
    // 主账号那行没有拖动把手，其余三个各一个。
    final handles = find.byWidgetPredicate((widget) => widget is CampusIcon && widget.icon == CampusIcons.dragHandle);
    expect(handles, findsNWidgets(3));

    // 把最后的代签账号（137）拖到其余账号的最前：代签账号可以排到自己的账号前面，但排不过主账号。
    final drag = await tester.startGesture(tester.getCenter(handles.last));
    await tester.pump(const Duration(milliseconds: 100));
    for (var step = 0; step < 15; step++) {
      await drag.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pumpAndSettle();
    // 写库在松手后异步进行：等到排序真的落库，不按固定时长赌磁盘速度。
    Future<List<String>> storedOrder(String expected) async => (await tester.runAsync(() async {
      for (var attempt = 0; attempt < 500; attempt++) {
        final current = [for (final item in await controller.accounts.list()) item.phoneNumber];
        if (current.join(',') == expected) return current;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return [for (final item in await controller.accounts.list()) item.phoneNumber];
    }))!;
    expect(await storedOrder('138,137,136,139'), ['138', '137', '136', '139'], reason: '拖动后的排序已写回库');

    // ⋯ 按行序：138（主账号）、137、136、139。代签账号的⋯里没有「设为主账号」。
    final menus = find.byTooltip('更多操作');
    await tester.tap(menus.at(1));
    await tester.pumpAndSettle();
    expect(find.text('改备注名'), findsOneWidget);
    expect(find.text('设为主账号'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // 自己的账号（136）设为主账号：置顶、标「主账号」，其余顺序不变。
    await tester.tap(menus.at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为主账号'));
    await tester.pumpAndSettle();
    expect(await storedOrder('136,138,137,139'), ['136', '138', '137', '139']);
    // 控制器刷新列表也走真实的库读写：等它落定再看界面。
    for (var round = 0; round < 250 && controller.mainPhoneNumber != '136'; round++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(controller.mainPhoneNumber, '136');
    await tester.pumpAndSettle();
    expect(find.text('136 · '), findsOneWidget);
    expect(find.text('主账号'), findsOneWidget);
    controller.dispose();
  });

  test('主账号：没设过取最早登录的自己账号，打开工具进它；设了别的就进设的；代签账号不能设；删掉主账号退回最早登录的', () async {
    await fake.addUser('13900139000', 'otherPassword1', name: '同学乙');
    final vault = MemoryChaoxingVault();
    final accounts = accountsWith(vault);
    await accounts.signIn(phoneNumber: '13800138000', password: 'myPassword123');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await accounts.signIn(phoneNumber: '13900139000', password: 'otherPassword1');
    // 更早登录的代签账号也不会被当成主账号。
    await store.putAccount(
      ChaoxingAccountRecord(
        phoneNumber: '13700137000',
        uid: 1,
        puid: 2,
        fid: 3,
        name: '同学丙',
        schoolName: '示例大学',
        deviceCode: 'device-137',
        isOtherUser: true,
        createdAt: DateTime.utc(2020),
      ),
    );
    Future<String> opened() async {
      final controller = ChaoxingController(accounts: accountsWith(vault));
      await controller.initialize();
      final phoneNumber = controller.current!.phoneNumber;
      controller.dispose();
      return phoneNumber;
    }

    // 以前打开进的是排第一的「最近登录的自己账号」（同学乙），现在进主账号（最早登录的同学甲）。
    expect((await accounts.list()).first.phoneNumber, '13800138000');
    expect(await opened(), '13800138000');

    await accounts.setMainAccount((await accounts.record('13900139000'))!);
    expect((await accounts.list()).first.phoneNumber, '13900139000');
    expect(await opened(), '13900139000');

    await expectLater(accounts.setMainAccount((await accounts.record('13700137000'))!), throwsA(isA<ChaoxingFailure>()));
    expect(await store.preference(chaoxingMainAccountKey), '13900139000');

    await accounts.forget('13900139000');
    expect(await store.preference(chaoxingMainAccountKey), isNull);
    expect((await accounts.list()).first.phoneNumber, '13800138000');
  });

  test('重新登录不清掉备注名与手动排序', () async {
    final accounts = accountsWith(MemoryChaoxingVault());
    await accounts.signIn(phoneNumber: '13800138000', password: 'myPassword123');
    await store.renameAccount('13800138000', '我自己');
    await store.reorderAccounts(['13700137000', '13800138000']);
    await accounts.signIn(phoneNumber: '13800138000', password: 'myPassword123');
    final again = (await accounts.record('13800138000'))!;
    expect(again.label, '我自己');
    expect(again.sort, 1);
  });

  testWidgets('手势连续画错后重画，提交的只是这一次的图案', (tester) async {
    final patterns = <String>[];
    String? error;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return ChaoxingGestureField(error: error, onCompleted: patterns.add);
                },
              ),
            ),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byType(ChaoxingGestureField));
    Offset dot(int index) => origin + Offset((index % 3 + 0.5) * 100, (index ~/ 3 + 0.5) * 100);
    Future<void> draw(List<int> dots) async {
      final gesture = await tester.startGesture(dot(dots.first));
      for (final index in dots.skip(1)) {
        await gesture.moveTo(dot(index));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
    }

    await draw([0, 1, 2]);
    rebuild(() => error = '手势码不对');
    await tester.pump();
    await draw([3, 4, 5]);
    // 第二次也错：error 一直挂着，不会再触发「从无到有」的清空。
    await draw([6, 7, 8]);
    expect(patterns, ['123', '456', '789']);
  });

  testWidgets('签到码满位后改光标位置不会重复提交，格子跟着显示输入', (tester) async {
    final controller = TextEditingController();
    var filled = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: campusTheme(),
        home: Scaffold(body: ChaoxingCodeCells(controller: controller, length: 4, onFilled: () => filled++)),
      ),
    );
    await tester.enterText(find.byType(TextField), '1234');
    await tester.pump();
    expect(filled, 1);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    await tester.tap(find.byType(ChaoxingCodeCells));
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    expect(filled, 1);
    controller.clear();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '5678');
    await tester.pump();
    expect(filled, 2);
    controller.dispose();
  });
}
