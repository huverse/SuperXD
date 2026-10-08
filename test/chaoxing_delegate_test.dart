import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_batch.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_share_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_sign_flow.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_vault.dart';

import 'chaoxing_fake_hub.dart';
import 'chaoxing_fake_server.dart';

// 代签是一条两台设备之间的链路：一台出示代签码，另一台扫码导入后替对方签到。
void main() {
  late Directory directory;
  late ChaoxingStore store;
  late MemoryChaoxingVault vault;
  late FakeChaoxing fake;
  late FakePackHub packs;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final root = await Directory(
      path.join(Directory.current.path, 'build', 'chaoxing_tests'),
    ).create(recursive: true);
    directory = await root.createTemp('case_');
    store = await ChaoxingStore.open(path.join(directory.path, 'a.db'));
    vault = MemoryChaoxingVault();
    fake = await FakeChaoxing.create();
    fake.courses = [
      {
        'content': {
          'id': 88,
          'course': {
            'data': [
              {'id': 9001, 'name': '高等数学'},
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
    packs = FakePackHub();
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  ChaoxingController controllerFor(ChaoxingStore ownStore, ChaoxingVault ownVault, {ChaoxingPackHub? hub}) => ChaoxingController(
    accounts: ChaoxingAccounts(
      store: ownStore,
      vault: ownVault,
      transport: (cookies) => ChaoxingHttp(client: fake.client(), cookies: cookies),
    ),
    hub: hub,
  );

  ChaoxingPackHub hub() => ChaoxingPackHub(baseUrl: Uri.parse('http://relay.test'), client: packs.client());

  testWidgets('出示页重新生成会作废上一张码，离开页面后当前这张也作废', (tester) async {
    final owner = controllerFor(store, vault, hub: hub());
    await tester.runAsync(() => owner.signIn('13800138000', 'myPassword123'));
    // 封包、投递都是真异步（加密库与网络桩），在假时钟里要靠 runAsync 让它们走完。
    // 上限约 10 秒（CI 慢机器留余量，只在失败时用满）；等不到就带上 what 直接失败，不静默返回让后面的断言莫名失败。
    Future<void> settle(String what, bool Function() done) async {
      for (var round = 0; round < 500 && !done(); round++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      if (!done()) fail('等待超时：$what');
    }

    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingTicketPage(controller: owner)));
    await settle('出示页投递完成并显示有效期', () => find.textContaining('10 分钟内有效').evaluate().isNotEmpty);
    final first = packs.packs.keys.single;

    await tester.ensureVisible(find.text('重新生成'));
    await tester.pump();
    await tester.tap(find.text('重新生成'));
    await settle('重新生成：旧码作废、中转上只剩新码', () => packs.packs.length == 1 && packs.packs.keys.single != first);
    expect(packs.packs.keys.single, isNot(first));
    expect(packs.calls.where((call) => call.endsWith('/revoke')), hasLength(1));

    await tester.pumpWidget(const SizedBox());
    await settle('离开出示页：当前码作废', () => packs.packs.isEmpty);
    expect(packs.packs, isEmpty);
    owner.dispose();
  });

  test('出示的代签码能在另一台设备导入，并带着对方的设备码签到', () async {
    final first = controllerFor(store, vault, hub: hub());
    await first.signIn('13800138000', 'myPassword123');
    final deviceCode = first.account!.deviceCode;

    final ticket = (await first.delegate.createTicket()).ticket;
    expect(ticket.startsWith('SXDC1:'), isTrue);
    expect(packs.packs, hasLength(1));

    // 另一台设备：自己的库与安全存储。
    final otherStore = await ChaoxingStore.open(path.join(directory.path, 'b.db'));
    final otherVault = MemoryChaoxingVault();
    final second = controllerFor(otherStore, otherVault, hub: hub());
    final imported = await second.importCredentialTicket(ticket);
    expect(imported.phoneNumber, '13800138000');
    expect(imported.isOtherUser, isTrue);
    expect(imported.name, '同学甲');
    // 设备码跟着凭据包走：用对方的设备码签到时学习通不会提示「更换了签到设备」。
    expect(imported.deviceCode, deviceCode);
    expect(await otherVault.readPassword('13800138000'), isNotNull);
    expect(packs.packs, isEmpty);

    // 导入后就能替他签，提交里带的是对方的设备码。
    await second.select(imported);
    expect(second.activities, isNotEmpty);
    final target = second.signTargets().single;
    await second.signTarget(
      target,
      second.activities.first,
      info: await second.activeInfo(second.activities.first),
      inputs: const ChaoxingSignInputs(signCode: '1234'),
      solveCaptcha: (_, _) async => null,
    );
    expect(fake.signQuery!['uid'], '7007');
    expect(fake.signQuery!['deviceCode'], deviceCode);
    second.dispose();
    await otherStore.close();
  });

  test('代签码可以附带人脸照片，导入方记进本机', () async {
    final first = controllerFor(store, vault, hub: hub());
    await first.signIn('13800138000', 'myPassword123');
    final ticket = (await first.delegate.createTicket(faceObjectIds: ['face-a', 'face-b'])).ticket;

    final otherStore = await ChaoxingStore.open(path.join(directory.path, 'f.db'));
    final second = controllerFor(otherStore, MemoryChaoxingVault(), hub: hub());
    final imported = await second.importCredentialTicket(ticket);
    expect((await second.faces.faceImages(imported)).map((image) => image.objectId), ['face-a', 'face-b']);
    await otherStore.close();
  });

  test('一次给本人与代签账号连签：按顺序逐个提交，各用各的设备码', () async {
    await fake.addUser('13900139000', 'otherPassword1', name: '同学乙');
    final controller = controllerFor(store, vault, hub: hub());
    // 先在另一台设备出示乙的代签码，再在本机导入。
    final otherStore = await ChaoxingStore.open(path.join(directory.path, 'g.db'));
    final owner = controllerFor(otherStore, MemoryChaoxingVault(), hub: hub());
    await owner.signIn('13900139000', 'otherPassword1');
    final ticket = (await owner.delegate.createTicket()).ticket;
    final otherCode = owner.account!.deviceCode;

    await controller.signIn('13800138000', 'myPassword123');
    await controller.importCredentialTicket(ticket);
    final targets = controller.signTargets();
    expect(targets.map((target) => target.selected), [isTrue, isFalse]);
    targets.last.selected = true;
    final batch = ChaoxingBatchSigning(targets);
    final activity = controller.activities.first;
    final info = await controller.activeInfo(activity);
    final codes = <String>[];
    final done = await batch.run((target, {required force}) async {
      final result = await controller.signTarget(
        target,
        activity,
        info: info,
        inputs: const ChaoxingSignInputs(signCode: '1234'),
        solveCaptcha: (_, _) async => null,
        force: force,
      );
      codes.add(fake.signQuery!['deviceCode']!);
      return result;
    }, interval: Duration.zero);
    expect(done, isTrue);
    expect(codes.last, otherCode);
    expect(codes.first, isNot(otherCode));
    controller.dispose();
    await otherStore.close();
  });

  test('签到前检查判定已签到时可以强制签到，强制时不再走 preSign', () async {
    final controller = controllerFor(store, vault);
    await controller.signIn('13800138000', 'myPassword123');
    final activity = controller.activities.first;
    final info = await controller.activeInfo(activity);
    final target = controller.signTargets().single;
    final batch = ChaoxingBatchSigning([target]);
    Future<ChaoxingSignResult> signer(ChaoxingSignTarget item, {required bool force}) => controller.signTarget(
      item,
      activity,
      info: info,
      inputs: const ChaoxingSignInputs(signCode: '1234'),
      solveCaptcha: (_, _) async => null,
      force: force,
    );

    fake.preSignHtml = '<script>signstatus = 1;</script>';
    expect(await batch.run(signer), isFalse);
    expect(target.state, ChaoxingTargetState.failed);
    expect(target.forceAvailable, isTrue);
    expect(fake.signQuery, isNull);

    fake.preSignBody = null;
    expect(await batch.retry(target, signer, force: true), isTrue);
    expect(fake.preSignBody, isNull);
    expect(fake.signQuery!['signCode'], '1234');
    controller.dispose();
  });

  test('同一张代签码只能取一次', () async {
    final first = controllerFor(store, vault, hub: hub());
    await first.signIn('13800138000', 'myPassword123');
    final ticket = (await first.delegate.createTicket()).ticket;

    final otherStore = await ChaoxingStore.open(path.join(directory.path, 'c.db'));
    final second = controllerFor(otherStore, MemoryChaoxingVault(), hub: hub());
    await second.importCredentialTicket(ticket);
    await expectLater(
      second.importCredentialTicket(ticket),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.packNotFound)),
    );
    await otherStore.close();
  });

  test('自己的账号不让导入，坏二维码也拦下', () async {
    final controller = controllerFor(store, vault, hub: hub());
    await controller.signIn('13800138000', 'myPassword123');

    await expectLater(
      controller.importCredentialTicket('SXDC1:not-a-ticket'),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.invalidInput)),
    );

    // 自己的另一台设备出示自己的代签码，拿到本人这台设备导入：库里已有本人账号，要拦下。
    final otherStore = await ChaoxingStore.open(path.join(directory.path, 'd.db'));
    final other = controllerFor(otherStore, MemoryChaoxingVault(), hub: hub());
    await other.signIn('13800138000', 'myPassword123');
    final ticket = (await other.delegate.createTicket()).ticket;
    await expectLater(
      controller.importCredentialTicket(ticket),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.message, 'message', contains('你自己的账号'))),
    );
    await otherStore.close();
  });

  test('没配中转时两条代签入口都不可用', () async {
    final controller = controllerFor(store, vault);
    await controller.signIn('13800138000', 'myPassword123');
    for (final action in [
      controller.delegate.createTicket,
      () => controller.importCredentialTicket('SXDC1:pickup0000000000.abc'),
    ]) {
      await expectLater(
        action(),
        throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.unavailable)),
      );
    }
  });

  test('切换学校单位后会话里的 fid 与签到提交都按所选单位走，重新登录也保留', () async {
    fake.unitConfigInfos = [
      {'fid': 1234, 'schoolname': '示例大学'},
      {'fid': 5678, 'schoolname': '乙培训'},
    ];
    final controller = controllerFor(store, vault);
    await controller.signIn('13800138000', 'myPassword123');
    expect(controller.current!.units.map((unit) => unit.fid), [1234, 5678]);
    await controller.selectUnit(const ChaoxingUnit(fid: 5678, name: '乙培训'));
    expect(controller.current!.fid, 5678);
    expect(controller.current!.schoolName, '乙培训');
    expect((await vault.readCookies('13800138000'))!['fid'], '5678');

    final activity = controller.activities.first;
    await controller.signTarget(
      controller.signTargets().single,
      activity,
      info: await controller.activeInfo(activity),
      inputs: const ChaoxingSignInputs(signCode: '1234'),
      solveCaptcha: (_, _) async => null,
    );
    expect(fake.signQuery!['fid'], '5678');

    // 再登录一次（同一台设备），所选单位不丢。
    await controller.signIn('13800138000', 'myPassword123');
    expect(controller.current!.fid, 5678);
    expect((await vault.readCookies('13800138000'))!['fid'], '5678');
    controller.dispose();
  });

  test('换模拟的客户端后请求的 UA 跟着换，并记进设置', () async {
    final controller = controllerFor(store, vault);
    await controller.signIn('13800138000', 'myPassword123');
    expect(fake.lastUserAgent, contains('com.chaoxing.mobile/'));
    await controller.setProfile(ChaoxingClientProfile.xuezaixidian);
    // 换完会刷新一次列表，这次请求带的就是学在西电的 UA。
    expect(fake.lastUserAgent, contains('com.chaoxing.mobile.xuezaixidian/'));
    expect(await store.preference(chaoxingProfileKey), 'xuezaixidian');
    final accounts = ChaoxingAccounts(store: store, vault: vault);
    await accounts.loadProfile();
    expect(accounts.profile.id, 'xuezaixidian');
    controller.dispose();
  });
}
