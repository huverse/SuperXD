import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
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
    while (!_GatedClient.used) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
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

  testWidgets('账号管理分本人与代签账号两段，代签段内拖动排序并写回', (tester) async {
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
      controller.accountList = await controller.accounts.list();
    });
    expect(controller.accountList.map((item) => item.phoneNumber), ['138', '139', '137']);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: const Scaffold(body: Center(child: Text('宿主')))));
    unawaited(showChaoxingAccountSheet(tester.element(find.text('宿主')), controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('本人'), findsOneWidget);
    expect(find.textContaining('代签账号 · 按住右侧把手拖动排序'), findsOneWidget);
    // 本人那行没有拖动把手，两个代签账号各一个。
    final handles = find.byWidgetPredicate((widget) => widget is CampusIcon && widget.icon == CampusIcons.dragHandle);
    expect(handles, findsNWidgets(2));

    final drag = await tester.startGesture(tester.getCenter(handles.last));
    await tester.pump(const Duration(milliseconds: 100));
    for (var step = 0; step < 10; step++) {
      await drag.moveBy(const Offset(0, -15));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    final ordered = await tester.runAsync(() => controller.accounts.list());
    expect(ordered!.map((item) => item.phoneNumber), ['138', '137', '139']);
    controller.dispose();
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
