import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
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

  test('出示的代签码能在另一台设备导入，并带着对方的设备码签到', () async {
    final first = controllerFor(store, vault, hub: hub());
    await first.signIn('13800138000', 'myPassword123');
    final deviceCode = first.account!.deviceCode;

    final ticket = await first.createCredentialTicket();
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
    await second.sign(second.activities.first, signCode: '1234');
    expect(fake.signQuery!['uid'], '7007');
    expect(fake.signQuery!['deviceCode'], deviceCode);
    await otherStore.close();
  });

  test('同一张代签码只能取一次', () async {
    final first = controllerFor(store, vault, hub: hub());
    await first.signIn('13800138000', 'myPassword123');
    final ticket = await first.createCredentialTicket();

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
    final ticket = await other.createCredentialTicket();
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
      controller.createCredentialTicket,
      () => controller.importCredentialTicket('SXDC1:pickup0000000000.abc'),
    ]) {
      await expectLater(
        action(),
        throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.unavailable)),
      );
    }
  });
}
